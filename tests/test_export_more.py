"""The export's own behaviour: how it prices, reads the edition, reports a sign-in failure, shows
progress, and how --validate groups what the role cannot read. A connector-shaped fake cursor stands in
for Snowflake; nothing here talks to a network.
"""
from __future__ import annotations

import datetime as dt
import json
import re
from pathlib import Path

import pyarrow as pa
import pytest

from app.core import datasource, reasons, registry
from tools import export_results as ex
from tools import first_run

NOW = dt.datetime(2026, 9, 21, 12, 0, tzinfo=dt.timezone.utc)
CHECK = "sf_wh_idle_minutes"
ENTERPRISE_CHECK = next(s.query_id for s in registry.load_registry()
                        if reasons.needs_enterprise(s.requires, s.empty_if) and not s.pre)


class SnowflakeError(Exception):
    def __init__(self, message: str, errno: int | None = None):
        super().__init__(message)
        self.errno = errno


class Cursor:
    """execute() logs and may raise; fetch_arrow_all() answers the export's own probes by their text."""

    def __init__(self, deny: dict[str, int] | None = None, edition: str | None = None, rates: list | None = None):
        self.deny, self.edition, self.rates = deny or {}, edition, rates
        self.log: list[str] = []
        self.last = ""

    def execute(self, sql: str):
        body = ex._COMMENT_RE.sub("", sql).strip()
        self.log.append(body)
        for needle, errno in self.deny.items():
            if needle in body:
                if errno == 904:
                    raise SnowflakeError(f"SQL compilation error: error line 1 at position 7 invalid identifier '{needle}'", errno)
                raise SnowflakeError(f"SQL compilation error: {needle} does not exist or not authorized.", errno)
        self.last = body
        return self

    def fetch_arrow_all(self) -> pa.Table:
        last = self.last
        if last.upper().startswith("SHOW"):
            raise RuntimeError("fetch_arrow_all is not supported for SHOW results")
        if "CURRENT_ACCOUNT()" in last and "AS a," in last:
            return pa.table({"A": ["ABC12345"], "R": ["AWS_US_EAST_1"], "N": ["ACCT"]})
        if "ORGANIZATION_USAGE.ACCOUNTS" in last:
            if self.edition is None:
                raise SnowflakeError("ORGANIZATION_USAGE.ACCOUNTS does not exist or not authorized.", 2003)
            return pa.table({"EDITION": [self.edition]})
        if "USAGE_IN_CURRENCY_DAILY" in last:
            return pa.table({"USAGE_KIND": ["compute", "storage"], "RATE": [3.0, 0.75],
                             "USAGE": [1000.0, 40.0], "DAYS": [90, 90]}) if self.rates is None else pa.table(self.rates)
        if "missing_from_show" in last:
            return pa.table({"METERED": [4], "MISSING_FROM_SHOW": [1]})
        if last.startswith("SELECT COUNT(*) AS n"):
            return pa.table({"N": [0]})
        return pa.table({"WINDOW_DAYS": [30], "STATUS": ["OK"]})

    @property
    def description(self):
        return None


class Conn:
    def __init__(self, cursor):
        self._c = cursor

    def cursor(self):
        return self._c

    def close(self):
        pass


def _export(tmp_path, cursor, **kw):
    kw.setdefault("only", [CHECK])
    return ex.run_export(tmp_path / "out", windows=30, connect_fn=lambda: Conn(cursor), now=NOW, **kw)


# ---- price: the effective rate, and where it came from ---------------------------------------------


def test_the_rate_sql_prices_only_consumption_and_leaves_out_ai_overage_and_rebates():
    sql = ex.org_rate_sql("ABC12345", NOW.date())
    assert "rating_type IN ('compute', 'storage')" in sql and "billing_type = 'consumption'" in sql
    assert "COALESCE(is_adjustment, FALSE) = FALSE" in sql
    assert "'overage'" in sql and "(AI|CORTEX)" in sql
    assert "usage_type ILIKE" not in sql, "the rate no longer guesses from the usage_type text"
    pattern = re.compile(r"(^|_)(AI|CORTEX)(_|$)")
    assert pattern.search("CORTEX_FUNCTIONS") and pattern.search("AI_SERVICES") and not pattern.search("CLOUD_SERVICES")
    assert not pattern.search("WAREHOUSE_METERING") and not pattern.search("SNOWPIPE_STREAMING")


def test_invoice_prices_are_marked_invoice_derived_with_their_basis(tmp_path):
    manifest = _export(tmp_path, Cursor())
    pricing = manifest["pricing"]
    assert pricing["source"] == "usage_in_currency_daily" and pricing["credit_price_usd"] == 3.0
    assert pricing["storage_source"] == "usage_in_currency_daily"
    assert pricing["storage_price_usd_tb_month"] == pytest.approx(0.75 * ex.DAYS_PER_MONTH)
    assert pricing["rate_basis"]["compute"] == {"days": 90, "usage": 1000.0}


def test_a_cli_price_wins_and_the_invoice_still_fills_the_other(tmp_path):
    pricing = _export(tmp_path, Cursor(), credit_price=4.0)["pricing"]
    assert pricing["source"] == "cli" and pricing["credit_price_usd"] == 4.0
    assert pricing["storage_source"] == "usage_in_currency_daily"
    both = _export(tmp_path, Cursor(), credit_price=4.0, storage_price=20.0)["pricing"]
    assert both["storage_source"] == "cli" and both["storage_price_usd_tb_month"] == 20.0


def test_a_settings_price_beats_the_invoice_and_is_not_marked_invoice(tmp_path, monkeypatch):
    real = ex.app_config.load_settings
    monkeypatch.setattr(ex.app_config, "load_settings",
                        lambda: {**real(), "credit_price_usd": 2.5, "storage_price_usd_tb_month": 21.0})
    pricing = _export(tmp_path, Cursor())["pricing"]
    assert (pricing["source"], pricing["credit_price_usd"]) == ("settings", 2.5)
    assert (pricing["storage_source"], pricing["storage_price_usd_tb_month"]) == ("settings", 21.0)


def test_no_price_anywhere_is_unpriced_never_zero(tmp_path):
    cur = Cursor(deny={"USAGE_IN_CURRENCY_DAILY": 2003})
    pricing = _export(tmp_path, cur)["pricing"]
    assert pricing["credit_price_usd"] is None and pricing["source"] is None


def test_the_report_header_names_price_edition_and_timeout(tmp_path):
    _export(tmp_path, Cursor(edition="ENTERPRISE"))
    head = (tmp_path / "out" / "report.md").read_text(encoding="utf-8")
    assert "price: $3 per credit (usage_in_currency_daily)" in head and "edition: ENTERPRISE" in head
    assert f"statement timeout: {ex.DEFAULT_STATEMENT_TIMEOUT_S} s" in head


# ---- edition ---------------------------------------------------------------------------------------


def test_the_edition_is_read_from_the_organization_accounts_view():
    assert ex.detect_edition(Cursor(edition="Business Critical")) == {
        "edition": "BUSINESS_CRITICAL", "source": "organization_usage.accounts", "evidence": []}


def test_without_org_access_the_edition_is_inferred_from_features_or_unknown():
    unknown = ex.detect_edition(Cursor())
    assert unknown["edition"] is None, "a missing feature never proves Standard"

    class WithMasking(Cursor):
        def fetch_arrow_all(self):
            if "MASKING_POLICIES" in self.last:
                return pa.table({"N": [3]})
            return super().fetch_arrow_all()

    inferred = ex.detect_edition(WithMasking())
    assert inferred == {"edition": "ENTERPRISE", "source": "feature_evidence", "evidence": ["masking policy"]}


def test_an_enterprise_check_on_a_standard_account_is_edition_too_low_and_not_run(tmp_path):
    cur = Cursor(edition="STANDARD")
    manifest = _export(tmp_path, cur, only=[ENTERPRISE_CHECK, "cost_by_hour_of_day"])
    entry = manifest["findings"][ENTERPRISE_CHECK]
    assert entry["status"] == "not_assessed" and entry["not_assessed_reason"] == "edition_too_low"
    assert entry["cause"] == "edition_too_low" and "Enterprise" in entry["error"]
    assert not (tmp_path / "out" / "findings" / f"{ENTERPRISE_CHECK}.parquet").exists()
    assert manifest["findings"]["cost_by_hour_of_day"]["status"] != "not_assessed"
    assert manifest["edition"]["edition"] == "STANDARD"
    same = _export(tmp_path, Cursor(edition="ENTERPRISE"), only=[ENTERPRISE_CHECK])
    assert same["findings"][ENTERPRISE_CHECK]["status"] != "not_assessed" or \
        same["findings"][ENTERPRISE_CHECK]["not_assessed_reason"] != "edition_too_low"


def test_the_reason_is_carried_into_the_run_results_and_the_api_vocabulary(tmp_path, monkeypatch):
    from tools import load_results
    monkeypatch.setattr(load_results, "_load_tags", lambda *a, **k: None)  # the fake cursor has no tag sources
    manifest = _export(tmp_path, Cursor(edition="STANDARD"), only=[ENTERPRISE_CHECK])
    assert manifest["findings"][ENTERPRISE_CHECK]["cause"] == "edition_too_low"
    summary = load_results.load_folder(tmp_path / "out", tmp_path / "t.duckdb")
    sidecar = json.loads(datasource.sidecar(tmp_path / "t.duckdb", "run_results").read_text(encoding="utf-8"))
    row = next(r for r in sidecar["results"] if r["query_id"] == ENTERPRISE_CHECK)
    assert row["status"] == "failed" and row["reason"] == "edition_too_low"
    assert summary["failed_in_export"][ENTERPRISE_CHECK].startswith("edition_too_low")


# ---- errors: one line with a code and the fix ------------------------------------------------------


@pytest.mark.parametrize("exc,code,fix", [
    (SnowflakeError("JWT token is invalid.", 390144), "390144", "RSA_PUBLIC_KEY"),
    (SnowflakeError("Incorrect username or password was specified.", 390100), "390100", "SNOWFLAKE_USER"),
    (SnowflakeError("Role 'X' specified in the connect string is not granted to this user.", 390189), "390189", "GRANT ROLE"),
    (SnowflakeError("No active warehouse selected in the current session.", 606), "606", "SNOWFLAKE_WAREHOUSE"),
    (SnowflakeError("Failed to connect to DB: abc.snowflakecomputing.com:443", 250001), "250001", "SNOWFLAKE_ACCOUNT"),
    (FileNotFoundError("[Errno 2] No such file or directory: 'rsa_key.p8'"), None, "SNOWFLAKE_PRIVATE_KEY_FILE"),
    (ImportError("DLL load failed"), None, "pip install"),
])
def test_a_connection_error_is_one_line_with_its_code_and_the_fix(exc, code, fix):
    line = ex.explain_connection_error(exc)
    assert "\n" not in line and "Traceback" not in line and fix in line
    if code:
        assert code in line


def test_a_failed_sign_in_raises_the_one_line_error_and_leaves_no_temp_folder(tmp_path):
    def boom():
        raise SnowflakeError("JWT token is invalid.", 390144)

    with pytest.raises(ex.ExportConnectionError) as info:
        ex.run_export(tmp_path / "out", windows=30, only=[CHECK], connect_fn=boom, now=NOW)
    assert "390144" in str(info.value) and "\n" not in str(info.value)
    assert not (tmp_path / "out.tmp").exists() and not (tmp_path / "out").exists()


def test_a_failure_on_the_first_statement_is_a_connection_error_too(tmp_path):
    with pytest.raises(ex.ExportConnectionError) as info:
        ex.run_export(tmp_path / "out", windows=30, only=[CHECK], now=NOW,
                      connect_fn=lambda: Conn(Cursor(deny={"CURRENT_ACCOUNT()": 606})))
    assert "606" in str(info.value)
    assert not (tmp_path / "out.tmp").exists()


def test_main_prints_the_line_and_exits_1_for_a_sign_in_failure(tmp_path, monkeypatch, capsys):
    def boom(*a, **k):
        raise SnowflakeError("Incorrect username or password was specified.", 390100)

    monkeypatch.setattr(ex, "connect", boom)
    rc = ex.main(["--out", str(tmp_path / "o"), "--only", CHECK])
    err = capsys.readouterr().err
    assert rc == 1 and err.startswith("error: ") and "390100" in err and "Traceback" not in err


# ---- progress and the timeout ----------------------------------------------------------------------


def test_progress_is_reported_after_every_check(tmp_path):
    seen = []
    _export(tmp_path, Cursor(), only=[CHECK, "cost_by_hour_of_day"], progress=lambda i, n, q, e: seen.append((i, n, q, e["status"])))
    assert [(i, n, q) for i, n, q, _ in seen] == [(1, 2, CHECK), (2, 2, "cost_by_hour_of_day")]


def test_the_progress_line_names_the_check_its_rows_and_time(capsys):
    ex._print_progress(3, 10, CHECK, {"status": "ok", "exported_rows": 12, "duration_s": 1.5})
    ex._print_progress(4, 10, "x", {"status": "failed", "error_code": "904", "duration_s": 0.2})
    ex._print_progress(5, 10, "y", {"status": "not_assessed", "not_assessed_reason": "edition_too_low", "duration_s": 0.0})
    out = capsys.readouterr().out.splitlines()
    assert out[0] == f"[3/10] {CHECK}: ok, 12 rows, 1.5s"
    assert out[1] == "[4/10] x: failed [904], 0.2s" and "edition_too_low" in out[2]


def test_the_session_carries_a_statement_timeout(monkeypatch):
    seen = {}

    class FakeConnector:
        @staticmethod
        def connect(**kwargs):
            seen.update(kwargs)
            return object()

    import sys
    import types
    module = types.ModuleType("snowflake.connector")
    module.connect = FakeConnector.connect
    package = types.ModuleType("snowflake")
    package.connector = module
    monkeypatch.setitem(sys.modules, "snowflake", package)
    monkeypatch.setitem(sys.modules, "snowflake.connector", module)
    monkeypatch.setattr(ex, "_statement_timeout_s", 321)
    ex.connect({"SNOWFLAKE_ACCOUNT": "a", "SNOWFLAKE_USER": "u", "SNOWFLAKE_PASSWORD": "p"})
    assert seen["session_parameters"]["STATEMENT_TIMEOUT_IN_SECONDS"] == 321
    assert seen["session_parameters"]["TIMEZONE"] == "UTC"


def test_a_timeout_is_recorded_as_a_timeout_and_the_rest_go_on(tmp_path):
    cur = Cursor()
    real = cur.execute

    def execute(sql):
        if "WAREHOUSE_METERING_HISTORY" in sql and "RESULT_SCAN" in sql:
            raise SnowflakeError("Statement reached its statement or warehouse timeout of 900 second(s) and was canceled.", 630)
        return real(sql)

    cur.execute = execute
    manifest = _export(tmp_path, cur, only=[CHECK, "cost_by_hour_of_day"])
    assert manifest["findings"][CHECK]["status"] == "failed" and manifest["findings"][CHECK]["cause"] == "timeout"
    assert manifest["findings"]["cost_by_hour_of_day"]["status"] in ("ok", "empty")


# ---- --validate: grouped by cause, one GRANT each ---------------------------------------------------


def _validate(tmp_path, cursor, only):
    return ex.run_validate(tmp_path / "v", windows=7, only=only, credit_price=3.0,
                           connect_fn=lambda: Conn(cursor), now=NOW)


def test_validate_separates_unreadable_from_failed_and_gives_the_grant(tmp_path):
    cur = Cursor(deny={"ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY": 2003, "ACCOUNT_USAGE.ACCESS_HISTORY": 3001,
                       "credits_billed": 904})
    only = [CHECK, "cost_by_hour_of_day", "sf_lin_blast_radius"]
    summary = _validate(tmp_path, cur, only)
    groups = ex.validate_groups(summary)
    unreadable = groups["unreadable"]["no_access"]
    assert CHECK in unreadable["checks"] and unreadable["grants"] == [
        "GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <audit_role>;"] + [
        g for g in unreadable["grants"][1:]]
    assert summary["checks"][CHECK]["status"] == "unreadable" and summary["checks"][CHECK]["cause"] == "no_access"
    assert all(e["status"] != "failed" for e in summary["checks"].values() if e["cause"] == "no_access")
    text = (tmp_path / "v" / "validate.md").read_text(encoding="utf-8")
    assert "The role can't read it" in text and "GRANT IMPORTED PRIVILEGES" in text and CHECK in text


def test_a_real_sql_error_is_failed_and_only_it_fails_the_run(tmp_path, monkeypatch, capsys):
    only = ["cost_by_hour_of_day"]
    summary = _validate(tmp_path, Cursor(deny={"usage_date": 904}), only)
    entry = summary["checks"]["cost_by_hour_of_day"]
    assert entry["status"] == "failed" and entry["cause"] == "sql_error" and entry["error_code"] == "904"
    assert "## SQL errors" in (tmp_path / "v" / "validate.md").read_text(encoding="utf-8")
    monkeypatch.setattr(ex, "connect", lambda *a, **k: Conn(Cursor(deny={"usage_date": 904})))
    assert ex.main(["--out", str(tmp_path / "v2"), "--validate", "--only", *only, "--credit-price", "3"]) == 1
    assert "SQL ERROR cost_by_hour_of_day [904]" in capsys.readouterr().out


def test_unreadable_sources_alone_exit_0(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(ex, "connect", lambda *a, **k: Conn(Cursor(deny={"ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY": 2003})))
    rc = ex.main(["--out", str(tmp_path / "v"), "--validate", "--only", CHECK, "--credit-price", "3"])
    out = capsys.readouterr().out
    assert rc == 0 and "0 SQL errors" in out and "The role can't read it" in out and "GRANT IMPORTED" in out


def test_a_standard_edition_check_is_edition_too_low_in_validate(tmp_path):
    cur = Cursor(edition="STANDARD", deny={"ACCOUNT_USAGE": 2003})
    summary = _validate(tmp_path, cur, [ENTERPRISE_CHECK])
    assert summary["checks"][ENTERPRISE_CHECK]["cause"] == "edition_too_low"
    assert summary["checks"][ENTERPRISE_CHECK]["status"] == "unreadable"
    assert "higher Snowflake edition" in (tmp_path / "v" / "validate.md").read_text(encoding="utf-8")


# ---- the shared vocabulary -------------------------------------------------------------------------


@pytest.mark.parametrize("message,code,cause", [
    ("SQL compilation error: Object 'X' does not exist or not authorized.", 2003, "no_access"),
    ("Insufficient privileges to operate on view 'X'", 3001, "no_access"),
    ("SQL compilation error: invalid identifier 'FOO'", 904, "sql_error"),
    ("Statement reached its statement or warehouse timeout of 900 second(s) and was canceled.", 630, "timeout"),
    ("SQL compilation error: this feature is not supported in your edition. Enterprise Edition is required.", None, "edition_too_low"),
    ("SQL compilation error: no such view 'A.B' in this account", None, "view_missing"),
])
def test_classify_error(message, code, cause):
    assert reasons.classify_error(message, code) == cause


def test_every_source_the_checks_read_has_a_grant_or_says_none_is_needed():
    for spec in registry.load_registry():
        for schema, name in spec.sources:
            key = f"SHOW {name}" if schema == "SHOW" else f"{schema}.{name}"
            line = reasons.grant_for(key)
            assert schema == "FUNCTION" or line, key
            assert schema == "FUNCTION" or "<audit_role>" in line or line.startswith("Use a role"), key


def test_trust_center_budgets_and_auth_policies_have_their_own_grant():
    assert "TRUST_CENTER_VIEWER" in reasons.grant_for("TRUST_CENTER.FINDINGS")
    assert "BUDGET_VIEWER" in reasons.grant_for("SHOW SNOWFLAKE.CORE.BUDGET INSTANCES")
    assert "APPLY AUTHENTICATION POLICY" in reasons.grant_for("SHOW AUTHENTICATION POLICIES")
    assert "APPLY PASSWORD POLICY" in reasons.grant_for("SHOW PASSWORD POLICIES")
    assert "ORGANIZATION_BILLING_VIEWER" in reasons.grant_for("ORGANIZATION_USAGE.RATE_SHEET_DAILY")
    assert "ORGANIZATION_USAGE_VIEWER" in reasons.grant_for("ORGANIZATION_USAGE.LOGIN_HISTORY")


# ---- first_run and refresh: prices and folder names ---------------------------------------------------


def test_first_run_passes_the_prices_to_the_export():
    args = first_run.parse_args(["--windows", "90", "--credit-price", "3.5", "--storage-price", "23"])
    cmd = first_run.export_argv(Path("out"), args)
    assert cmd[-4:] == ["--credit-price", "3.5", "--storage-price", "23.0"]
    assert "--credit-price" not in first_run.export_argv(Path("out"), first_run.parse_args([]))


def test_first_run_still_refuses_a_credential_shaped_flag():
    first_run.build_parser()  # the self-check inside raises for "token", "password", "secret", "credential"


def test_first_run_and_refresh_name_the_folder_the_same_way_and_newest_is_last(tmp_path):
    stamp = first_run._stamp(NOW)
    assert stamp == datasource.results_stamp(NOW) == "20260921T120000Z"
    for name in ("20260920T101500Z", "20260921-090000", "20260921T120000Z", "20260101T000000Z"):
        (tmp_path / "results" / name).mkdir(parents=True)
    assert [p.name for p in datasource.results_folders(tmp_path)] == [
        "20260921T120000Z", "20260921-090000", "20260920T101500Z", "20260101T000000Z"]


def test_refresh_uses_the_export_default_row_cap_and_the_shared_stamp():
    source = (Path(__file__).resolve().parent.parent / "app" / "api" / "refresh.py").read_text(encoding="utf-8")
    assert "--max-rows" not in source.split("def _run", 1)[1].split("def _remove_old_dbs", 1)[0].replace(
        "# No --max-rows: the export's own default", "")
    assert "datasource.results_stamp()" in source
    assert 'strftime("%Y%m%d-%H%M%S")' not in source


def test_refresh_passes_on_a_typed_price_but_reads_an_invoice_storage_price_again(tmp_path):
    from app.api import refresh
    folder = tmp_path / "results" / "20260921T120000Z"
    folder.mkdir(parents=True)
    (folder / "manifest.json").write_text(json.dumps({"pricing": {
        "source": "cli", "credit_price_usd": 4.0, "storage_price_usd_tb_month": 22.5,
        "storage_source": "usage_in_currency_daily"}}), encoding="utf-8")
    assert refresh._last_prices(tmp_path) == ["--credit-price", "4.0"]
    (folder / "manifest.json").write_text(json.dumps({"pricing": {
        "source": "cli", "credit_price_usd": 4.0, "storage_price_usd_tb_month": 22.5, "storage_source": "cli"}}),
        encoding="utf-8")
    assert refresh._last_prices(tmp_path) == ["--credit-price", "4.0", "--storage-price", "22.5"]


def test_the_settings_price_keys_validate():
    from app.core import config
    assert config.DEFAULT_SETTINGS["credit_price_usd"] is None
    ok = config._validate_settings({"credit_price_usd": 3.2, "storage_price_usd_tb_month": 23})
    assert ok["credit_price_usd"] == 3.2
    for bad in ({"credit_price_usd": 0}, {"credit_price_usd": "3"}, {"storage_price_usd_tb_month": -1}):
        with pytest.raises(config.SettingsError):
            config._validate_settings(bad)


# ---- the README states the real count ---------------------------------------------------------------


def test_the_readme_counts_the_checks_that_exist():
    text = (Path(__file__).resolve().parent.parent / "README.md").read_text(encoding="utf-8")
    claimed = int(re.search(r"It runs (\d+) SQL checks", text).group(1))
    assert claimed == sum(1 for s in registry.load_registry() if s.executable)
    assert "[12/" in text and "openssl genrsa 2048" in text and "TRUST_CENTER_VIEWER" in text
    assert "BUDGET_VIEWER" in text and "APPLY AUTHENTICATION POLICY" in text and "Download ZIP" in text
    assert "source .venv/bin/activate" in text and r".venv\Scripts\Activate.ps1" in text
    assert not re.search(r"[A-Za-z]:\\Users\\", text), "no absolute local path in the README"
