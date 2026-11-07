"""Other kinds of account, made from the demo account, to look at every blocked and empty state.

apply() changes the loaded fake views; wrap() returns a connection that refuses or fails the named sources
with the errors Snowflake gives, so the export reacts as it does on a real account.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import re

from tests.fake_snowflake import demo_worst_case
from tests.fake_snowflake import schema as fake_schema

_ENTERPRISE_ONLY = ("ACCESS_HISTORY", "POLICY_REFERENCES", "MASKING_POLICIES", "ROW_ACCESS_POLICIES", "TAG_REFERENCES",
                    "MATERIALIZED_VIEW_REFRESH_HISTORY", "SEARCH_OPTIMIZATION_HISTORY")
_ORG = r"ORGANIZATION_USAGE\.\w+"
_PRIVATE_VIEWS = tuple(rf"ACCOUNT_USAGE\.{v}\b" for v in (
    "ACCESS_HISTORY", "GRANTS_TO_ROLES", "GRANTS_TO_USERS", "LOGIN_HISTORY", "MASKING_POLICIES", "POLICY_REFERENCES",
    "ROLES", "ROW_ACCESS_POLICIES", "SESSIONS", "TAG_REFERENCES", "USERS", "QUERY_ATTRIBUTION_HISTORY"))
_PRIVATE_SHOWS = ("SHOW INTEGRATIONS", "SHOW SECURITY INTEGRATIONS", "SHOW AUTHENTICATION POLICIES", "SHOW PASSWORD POLICIES",
                  "SHOW RESOURCE MONITORS", "SHOW SNOWFLAKE.CORE.BUDGET INSTANCES")
_TIMED_OUT = (630, "Statement reached its statement or warehouse timeout of 900 second(s) and was canceled.")
_BROKE = (100038, "Numeric value 'x' is not recognized")


@dataclasses.dataclass(frozen=True)
class Scenario:
    about: str
    blocked: tuple = ()                   # sources the role can't open: regex on the SQL
    failing: dict = dataclasses.field(default_factory=dict)   # regex -> (error number, message), when a check reads it
    empty: tuple = ()                     # account usage views that return no rows
    edition: str | None = None            # what ORGANIZATION_USAGE.ACCOUNTS says
    history_days: int | None = None       # the account is only this old
    nothing: bool = False                 # an account nobody has used yet
    partial_warehouses: bool = False      # SHOW WAREHOUSES lists only some
    in_trouble: bool = False              # past the thresholds: see demo_worst_case


SCENARIOS = {
    "full": Scenario("Enterprise, every source readable, a year of history"),
    "no_org_access": Scenario("A role without ORGANIZATION_USAGE: no invoice or rate sheet, no other accounts",
                              blocked=(_ORG,)),
    "limited_role": Scenario("A narrow role: no org views, no people, grants, policies or access history; SHOW sees part",
                             blocked=(_ORG, *_PRIVATE_VIEWS, r"TRUST_CENTER\.\w+", r"\bLOCAL\.\w+", *_PRIVATE_SHOWS),
                             partial_warehouses=True),
    "standard_edition": Scenario("Standard edition, detected: Enterprise-only checks read as needing Enterprise",
                                 edition="STANDARD", empty=_ENTERPRISE_ONLY),
    "standard_undetected": Scenario("Standard edition the export can't detect: the same views are simply empty",
                                    blocked=(_ORG,), empty=_ENTERPRISE_ONLY),
    "new_account": Scenario("An account 21 days old: long windows and old bands have no history", history_days=21),
    "unused_account": Scenario("An account with nothing in it: every view is empty", nothing=True),
    "worst_case": Scenario("An account in trouble: the CRITICAL and WARN results no other account reaches", in_trouble=True),
    "failing_checks": Scenario("Sources that open but fail when read: timeouts and a SQL error", failing={
        r"ACCOUNT_USAGE\.QUERY_ATTRIBUTION_HISTORY\b": _TIMED_OUT, r"ACCOUNT_USAGE\.ACCESS_HISTORY\b": _TIMED_OUT,
        r"ACCOUNT_USAGE\.TABLE_STORAGE_METRICS\b": _BROKE, r"ACCOUNT_USAGE\.LOGIN_HISTORY\b": _BROKE}),
}


class ScenarioError(Exception):
    """Stands in for snowflake.connector.errors.ProgrammingError: same message and errno."""

    def __init__(self, errno: int, message: str):
        super().__init__(message)
        self.errno = errno


def _tables(con) -> list[tuple[str, str]]:
    return [(s, t) for s, t in con.execute(
        "SELECT table_schema, table_name FROM information_schema.tables WHERE table_catalog = ?",
        [fake_schema.SNOWFLAKE_DB]).fetchall()]


def _shorten_history(con, days: int, as_of: dt.date) -> None:
    """Event rows before the account existed go; an object older than that is moved up to its first day."""
    cut = dt.datetime.combine(as_of - dt.timedelta(days=days), dt.time())
    for schema, table in _tables(con):
        full = f"{fake_schema.SNOWFLAKE_DB}.{schema}.{table}"
        cols = [(c, ty) for c, ty in con.execute(
            "SELECT column_name, data_type FROM information_schema.columns WHERE table_catalog = ? AND table_schema = ? "
            "AND table_name = ? ORDER BY ordinal_position", [fake_schema.SNOWFLAKE_DB, schema, table]).fetchall()
            if ty.startswith(("TIMESTAMP", "DATE"))]
        if not cols:
            continue
        is_object = any("CREATED" in c.upper() for c, _ in cols)
        if not is_object:
            con.execute(f'DELETE FROM {full} WHERE "{cols[0][0]}" < ?', [cut])
            continue
        for c, ty in cols:
            con.execute(f'UPDATE {full} SET "{c}" = CAST(? AS {ty}) WHERE "{c}" < ?', [cut, cut])


def apply(con, name: str, as_of: dt.date) -> None:
    s = SCENARIOS[name]
    db = fake_schema.SNOWFLAKE_DB
    if s.nothing:
        for schema, table in _tables(con):
            if table.upper() != "ACCOUNTS":
                con.execute(f"DELETE FROM {db}.{schema}.{table}")
    for view in s.empty:
        con.execute(f"DELETE FROM {db}.account_usage.{view}")
    if s.edition:
        con.execute(f"UPDATE {db}.organization_usage.ACCOUNTS SET edition = ?", [s.edition])
    if s.history_days:
        _shorten_history(con, s.history_days, as_of)
    if s.in_trouble:
        demo_worst_case.apply(con, as_of)
    if s.partial_warehouses:
        con.execute(f'DELETE FROM {db}.{fake_schema.SHOW_SCHEMA}.warehouses WHERE hash("name") % 2 = 0')


class _Cursor:
    def __init__(self, inner, scenario: Scenario):
        self._inner, self._s = inner, scenario

    def __getattr__(self, name):
        return getattr(self._inner, name)

    def execute(self, sql: str):
        for pattern in self._s.blocked:
            hit = re.search(pattern, sql, re.I)
            if hit:
                raise ScenarioError(2003, f"SQL compilation error: Object '{hit.group(0)}' does not exist or not authorized.")
        if not re.search(r"\bLIMIT\s+0\s*$", sql.strip(), re.I):       # the probe only opens a view
            for pattern, (errno, message) in self._s.failing.items():
                if re.search(pattern, sql, re.I):
                    raise ScenarioError(errno, message)
        self._inner.execute(sql)
        return self


class _Connection:
    def __init__(self, inner, scenario: Scenario):
        self._inner, self._s = inner, scenario

    def cursor(self):
        return _Cursor(self._inner.cursor(), self._s)

    def close(self):
        self._inner.close()


def wrap(connection, name: str):
    return _Connection(connection, SCENARIOS[name])
