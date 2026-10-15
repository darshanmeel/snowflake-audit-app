"""Deterministic fake rows for a small Snowflake account (fixed seed, fixed as-of).

The account has six warehouses (one multi-cluster, one idle, one adaptive with no attribution, one
with auto-suspend off and no monitor, one Snowpark-optimized), a dozen users and roles including
admins and people without MFA, queries with failures and spills, tasks with failures, pipes, dynamic
tables, storage with Fail-safe rows that have NULL names, tags and policies, and an organization of
three accounts. Cloud services run above 10% of compute on a few days and below on the rest.

`load(con, as_of)` fills the tables schema.create_all made. Nothing here is a real name.
"""
from __future__ import annotations

import datetime as dt
import json
import random
import zlib

import pyarrow as pa

from tests.fake_snowflake import (batch3_data, gap2_data, gap_cost_data, gap_platform_data, gap_security_data,
                                  new_checks_data, schema)

SEED = 20260921
NOW = dt.datetime(2026, 9, 21, 12, 0, 0, tzinfo=dt.timezone.utc)
ACCOUNT_LOCATOR = "FAKE01"
ACCOUNT_NAME = "FAKE_ACCOUNT"
REGION = "AWS_US_EAST_1"
ORG_NAME = "FAKE_ORG"
CREDIT_PRICE = 3.0
STORAGE_PRICE_TB_DAY = 23.0 / 30.4

HISTORY_DAYS = 200      # daily and hourly metering
QUERY_DAYS = 130        # QUERY_HISTORY and what hangs off it
DEMO_QUERY_DAYS = 185   # the demo's: a 90-day window and the one before it
DEMO_OLD_SHARE = 0.82   # demo query volume DEMO_QUERY_DAYS back, as a share of today's: steady, modest growth


def demo_share(k: int) -> float:
    """Demo statement volume k days back vs today: a straight line, so no month jumps."""
    return 1.0 - (1.0 - DEMO_OLD_SHARE) * min(max(k, 0), DEMO_QUERY_DAYS) / DEMO_QUERY_DAYS


# Busier than their archetype, so the per-warehouse checks have enough statements to judge
DEMO_VOLUME = {"WH_SHARED_ADAPTIVE": 3.0, "WH_REVERSE_ETL": 2.9, "WH_PLATFORM_DEV": 1.6}


def _wh_show(row: dict) -> dict:
    """A SHOW WAREHOUSES row; an ADAPTIVE warehouse shows no size, clusters, auto-suspend or generation, as live."""
    if row["type"] == "ADAPTIVE":
        row.update(state="ENABLED", size=None, min_cluster_count=None, max_cluster_count=None,
                   started_clusters=None, auto_suspend=None, scaling_policy=None, enable_query_acceleration=None,
                   query_acceleration_max_scale_factor=None, resource_constraint=None, generation=None,
                   query_throughput_multiplier=2, max_query_performance_level="Small")
    return row


LOAD_DAYS = 92          # 5-minute warehouse load

DML_LOCK_TYPES = ("INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "TRUNCATE_TABLE")   # statements that wait on locks
RATE = {"X-Small": 1, "Small": 2, "Medium": 4, "Large": 8, "X-Large": 16, "2X-Large": 32, "3X-Large": 64,
        "4X-Large": 128, "5X-Large": 256, "6X-Large": 512}

_ARROW = {"VARCHAR": pa.string(), "BIGINT": pa.int64(), "DOUBLE": pa.float64(),
          "TIMESTAMP": pa.timestamp("us"), "DATE": pa.date32(), "BOOLEAN": pa.bool_(), "JSON": pa.string()}


def _insert(con, schema_name: str, view: str, rows: list[dict]) -> None:
    """Rows are dicts keyed by lower-case column name; missing columns are NULL, unknown ones an error."""
    if not rows:
        return
    cols = schema.VIEWS[schema_name][view] if schema_name in schema.VIEWS else schema.SHOW_TABLES[view]
    known = {c.lower(): (c, t) for c, t in cols}
    for row in rows[:2000]:
        bad = set(row) - set(known)
        if bad:
            raise KeyError(f"{schema_name}.{view}: unknown column(s) {sorted(bad)}")
    arrays, names = [], []
    for low, (name, typ) in known.items():
        vals = [schema.coerce(r.get(low), typ) for r in rows]
        arrays.append(pa.array(vals, type=_ARROW[typ]))
        names.append(name)
    table = pa.Table.from_arrays(arrays, names=names)
    target = (f"{schema.SNOWFLAKE_DB}.{schema.SHOW_SCHEMA}" if schema_name == "show"
              else f"{schema.SNOWFLAKE_DB}.{schema_name}")
    con.register("_fake_rows", table)
    con.execute(f"INSERT INTO {target}.{view} BY NAME SELECT * FROM _fake_rows")
    con.unregister("_fake_rows")


def _t(day: dt.date, hour: int = 0, minute: int = 0, second: int = 0) -> dt.datetime:
    return dt.datetime(day.year, day.month, day.day, hour, minute, second)


class World:
    """Everything the views need, built once from one seeded generator."""

    def __init__(self, as_of: dt.date, demo: bool = False):
        self.as_of = as_of
        self.demo = demo
        self.rng = random.Random(SEED)
        self.now = dt.datetime(as_of.year, as_of.month, as_of.day, 12, 0, 0)
        self.rows: dict[tuple[str, str], list[dict]] = {}
        self._id = 900000
        self.build()

    # ---- helpers ---------------------------------------------------------------------------
    def add(self, schema_name: str, view: str, row: dict) -> None:
        self.rows.setdefault((schema_name, view), []).append(row)

    def au(self, view: str, row: dict) -> None:
        self.add("account_usage", view, row)

    def ou(self, view: str, row: dict) -> None:
        self.add("organization_usage", view, row)

    def show(self, view: str, row: dict) -> None:
        self.add("show", view, row)

    def next_id(self) -> int:
        self._id += 1
        return self._id

    def day(self, back: int) -> dt.date:
        return self.as_of - dt.timedelta(days=back)

    def days(self, n: int):
        return [self.day(i) for i in range(n, 0, -1)]   # oldest first, last is as_of - 1

    def is_weekday(self, d: dt.date) -> bool:
        return d.weekday() < 5

    def choice(self, seq, weights=None):
        return self.rng.choices(seq, weights=weights)[0]

    # ---- build order -------------------------------------------------------------------------
    def build(self) -> None:
        self.warehouses()
        self.users_roles_grants()
        self.objects()
        self.queries()
        self.tasks_alerts()
        self.dynamic_tables()
        self.metering()
        self.serverless()
        self.loading()
        self.storage()
        self.governance()
        self.access_history()
        self.warehouse_load_events()
        self.ai_and_other()
        self.organization()
        self.show_outputs()
        new_checks_data.add(self)
        batch3_data.add(self)
        batch3_data.add_cold_cache_day(self)
        gap_cost_data.add(self)
        gap_platform_data.add(self)
        gap_security_data.add(self)
        gap2_data.add(self)
        if self.demo:
            from tests.fake_snowflake import demo_data
            demo_data.add(self)

    # ---- warehouses --------------------------------------------------------------------------
    def warehouses(self) -> None:
        # id, name, size, type, min, max, auto_suspend_s, monitor, owner, attribution
        self.wh = [
            dict(id=1001, name="WH_ETL", size="Large", type="STANDARD", min=1, max=3, suspend=60,
                 monitor="RM_ETL", owner="SYSADMIN", attributed=True),
            dict(id=1002, name="WH_BI", size="Medium", type="STANDARD", min=1, max=1, suspend=300,
                 monitor="RM_BI", owner="SYSADMIN", attributed=True),
            dict(id=1003, name="WH_ADHOC", size="Small", type="STANDARD", min=1, max=1, suspend=0,
                 monitor=None, owner="ACCOUNTADMIN", attributed=True),
            dict(id=1004, name="WH_IDLE", size="X-Small", type="STANDARD", min=1, max=1, suspend=3600,
                 monitor=None, owner="SYSADMIN", attributed=True),
            dict(id=1005, name="WH_ADAPTIVE", size="Medium", type="ADAPTIVE", min=1, max=1, suspend=120,
                 monitor=None, owner="SYSADMIN", attributed=False),
            dict(id=1006, name="WH_ML", size="Medium", type="SNOWPARK-OPTIMIZED", min=1, max=1,
                 suspend=120, monitor="RM_BI", owner="DATA_ADMIN", attributed=True),
        ]
        self.wh_by_name = {w["name"]: w for w in self.wh}
        self.demo_wh_names: set[str] = set()
        if self.demo:
            self.demo_warehouses()

    # ---- users, roles, grants ------------------------------------------------------------------
    def users_roles_grants(self) -> None:
        d = self.as_of
        # name, type, default_role, has_password, has_mfa, has_rsa, last_login_days_ago, pw_age_days,
        # disabled, created_days_ago, deleted
        users = [
            ("ADMIN_ALICE", "PERSON", "ACCOUNTADMIN", True, True, False, 1, 30, False, 900, False),
            ("ADMIN_BOB", "PERSON", "ACCOUNTADMIN", True, False, False, 2, 500, False, 800, False),
            ("ANALYST_CARA", "PERSON", "ANALYST_ROLE", True, False, False, 3, 420, False, 700, False),
            ("ANALYST_DAN", "PERSON", "ANALYST_ROLE", True, True, False, 1, 60, False, 650, False),
            ("ANALYST_EVA", "PERSON", "BI_ROLE", False, False, False, 1, None, False, 600, False),
            ("ANALYST_FRANK", "PERSON", "ANALYST_ROLE", True, False, False, 220, 300, False, 640, False),
            ("DEV_GINA", "PERSON", "DEV_ROLE", True, True, False, 40, 90, True, 500, False),
            ("DEV_HUGO", "PERSON", "DEV_ROLE", True, False, False, 2, 200, False, 480, False),
            ("SVC_ETL", "SERVICE", "ETL_ROLE", False, False, True, 0, None, False, 700, False),
            ("SVC_BI", "SERVICE", "BI_ROLE", False, False, True, 0, None, False, 700, False),
            ("SVC_LEGACY", "LEGACY_SERVICE", "ETL_ROLE", True, False, False, 5, 800, False, 1000, False),
            ("SVC_NOKEY", "SERVICE", "DEV_ROLE", False, False, False, 100, None, False, 400, False),
            ("EX_IVAN", "PERSON", "DEV_ROLE", True, False, False, 150, 400, False, 900, True),
        ]
        self.users = []
        for i, (name, typ, role, pw, mfa, rsa, last, pwage, disabled, created, deleted) in enumerate(users):
            uid = 5001 + i
            self.users.append(name)
            self.au("USERS", dict(
                user_id=uid, name=name, login_name=name, email=f"{name.lower()}@example.com", type=typ,
                disabled=disabled, snowflake_lock=False, has_password=pw if typ == "PERSON" or pw else None,
                must_change_password=False, has_mfa=mfa if typ == "PERSON" else None,
                ext_authn_duo=False, has_rsa_public_key=rsa, has_pat=False, has_workload_identity=False,
                last_success_login=_t(self.day(last), 9) if last is not None else None,
                password_last_set_time=_t(self.day(pwage), 8) if pwage is not None else None,
                created_on=_t(self.day(created), 10), deleted_on=_t(self.day(100), 8) if deleted else None,
                owner="USERADMIN", default_role=role, default_secondary_role="ALL" if name == "DEV_HUGO" else None,
                default_warehouse="WH_ADHOC", is_from_organization_user=False))
        roles = ["ACCOUNTADMIN", "SECURITYADMIN", "SYSADMIN", "USERADMIN", "PUBLIC", "ORGADMIN",
                 "ETL_ROLE", "BI_ROLE", "ANALYST_ROLE", "DEV_ROLE", "DATA_ADMIN", "UNUSED_ROLE",
                 "GHOST_ROLE", "HUGO_ROLE"]
        for i, r in enumerate(roles):
            self.au("ROLES", dict(
                role_id=6001 + i, name=r, owner="ACCOUNTADMIN" if i < 6 else "SECURITYADMIN",
                role_type="ROLE", owner_role_type="ROLE", created_on=_t(self.day(1000 - i), 9),
                deleted_on=_t(self.day(30), 9) if r == "GHOST_ROLE" else None, comment=None,
                is_from_organization_user_group=False))
        self.au("ROLES", dict(role_id=6100, name="RAW_READER", owner="SYSADMIN", role_type="DATABASE_ROLE",
                              role_database_name="RAW_DB", owner_role_type="ROLE",
                              created_on=_t(self.day(300), 9)))
        self.roles = roles
        # role -> role grants: child NAME granted to parent GRANTEE_NAME
        hierarchy = [("SYSADMIN", "ACCOUNTADMIN"), ("SECURITYADMIN", "ACCOUNTADMIN"),
                     ("USERADMIN", "SECURITYADMIN"), ("DATA_ADMIN", "SYSADMIN"), ("ETL_ROLE", "DATA_ADMIN"),
                     ("BI_ROLE", "DATA_ADMIN"), ("ANALYST_ROLE", "BI_ROLE"), ("DEV_ROLE", "SYSADMIN"),
                     ("UNUSED_ROLE", "DEV_ROLE"), ("PUBLIC", "ANALYST_ROLE")]
        for child, parent in hierarchy:
            self.grant("USAGE", "ROLE", child, parent, granted_by="SECURITYADMIN")
        # privileges
        for wh, roles_ in {"WH_ETL": ["ETL_ROLE"], "WH_BI": ["BI_ROLE", "ANALYST_ROLE"],
                           "WH_ADHOC": ["PUBLIC", "DEV_ROLE"], "WH_IDLE": ["DEV_ROLE"],
                           "WH_ADAPTIVE": ["ANALYST_ROLE"], "WH_ML": ["DATA_ADMIN"]}.items():
            self.grant("OWNERSHIP", "WAREHOUSE", wh, self.wh_by_name[wh]["owner"], granted_by="ACCOUNTADMIN")
            for r in roles_:
                self.grant("USAGE", "WAREHOUSE", wh, r)
                self.grant("OPERATE", "WAREHOUSE", wh, r)
        for db, owner in [("RAW_DB", "SYSADMIN"), ("ANALYTICS_DB", "SYSADMIN"), ("SANDBOX_DB", "DEV_ROLE"),
                          ("DEV_DB", "DEV_ROLE")]:
            self.grant("OWNERSHIP", "DATABASE", db, owner)
            self.grant("USAGE", "DATABASE", db, "ANALYST_ROLE")
            self.grant("USAGE", "DATABASE", db, "PUBLIC" if db == "SANDBOX_DB" else "BI_ROLE")
            self.grant("CREATE SCHEMA", "DATABASE", db, "DEV_ROLE")
        self.grant("SELECT", "TABLE", "ANALYTICS_DB.CORE.CUSTOMERS", "ANALYST_ROLE", schema_="CORE",
                   catalog="ANALYTICS_DB")
        self.grant("SELECT", "TABLE", "ANALYTICS_DB.CORE.ORDERS", "BI_ROLE", schema_="CORE", catalog="ANALYTICS_DB")
        self.grant("SELECT", "TABLE", "ANALYTICS_DB.CORE.ORDERS", "PUBLIC", schema_="CORE", catalog="ANALYTICS_DB")
        self.grant("SELECT", "TABLE", "SANDBOX_DB.SCRATCH.TMP_A", "PUBLIC", schema_="SCRATCH", catalog="SANDBOX_DB")
        for p in ["ALL", "SELECT", "INSERT", "UPDATE", "DELETE"]:
            self.grant(p, "TABLE", "RAW_DB.LANDING.ORDERS_RAW", "DEV_ROLE", schema_="LANDING", catalog="RAW_DB",
                       option=(p == "ALL"))
        self.grant("SELECT", "SCHEMA", "ANALYTICS_DB.MARTS", "BI_ROLE", schema_="MARTS", catalog="ANALYTICS_DB")
        for p in ["MANAGE GRANTS", "CREATE ROLE", "CREATE USER", "CREATE WAREHOUSE", "MONITOR USAGE",
                  "EXECUTE TASK", "IMPORT SHARE", "CREATE INTEGRATION"]:
            self.grant(p, "ACCOUNT", ACCOUNT_NAME, "SECURITYADMIN" if p.startswith("CREATE ROLE") or p == "MANAGE GRANTS"
                       else "SYSADMIN")
        self.grant("MANAGE GRANTS", "ACCOUNT", ACCOUNT_NAME, "DATA_ADMIN")
        self.grant("MONITOR USAGE", "ACCOUNT", ACCOUNT_NAME, "ETL_ROLE")
        self.grant("USAGE", "INTEGRATION", "S3_INT", "DATA_ADMIN")
        self.grant("OWNERSHIP", "SCHEMA", "RAW_DB.LANDING", "ETL_ROLE", schema_="LANDING", catalog="RAW_DB")
        self.grant("OWNERSHIP", "SCHEMA", "ANALYTICS_DB.MARTS", "DATA_ADMIN", schema_="MARTS", catalog="ANALYTICS_DB")
        self.grant("OWNERSHIP", "SCHEMA", "ANALYTICS_DB.CORE", "SYSADMIN", schema_="CORE", catalog="ANALYTICS_DB")
        self.grant("USAGE", "ROLE", "OLD_ROLE", "UNUSED_ROLE", deleted=True)
        self.grant("USAGE", "STAGE", "S3_LANDING", "ETL_ROLE", schema_="LANDING", catalog="RAW_DB")
        self.grant("READ", "STAGE", "S3_ARCHIVE", "PUBLIC", schema_="LANDING", catalog="RAW_DB")
        self.grant("USAGE", "STAGE", "S3_ARCHIVE", "ANALYST_ROLE", schema_="LANDING", catalog="RAW_DB")
        self.grant("OWNERSHIP", "STAGE", "S3_LANDING", "ETL_ROLE", schema_="LANDING", catalog="RAW_DB")
        self.grant("READ", "SECRET", "SEC_DB_PW", "ETL_ROLE", schema_="SECRETS", catalog="SEC_DB")
        # account-usage readers: a default ACCOUNTADMIN, a wide analyst role and a small one
        self.grant("IMPORTED PRIVILEGES", "DATABASE", "SNOWFLAKE", "ACCOUNTADMIN", granted_by="", days_back=700)
        self.grant("USAGE", "DATABASE_ROLE", "SNOWFLAKE.USAGE_VIEWER", "ANALYST_ROLE", granted_by="ACCOUNTADMIN", days_back=200)
        self.grant("USAGE", "DATABASE_ROLE", "SNOWFLAKE.GOVERNANCE_VIEWER", "ANALYST_ROLE", granted_by="ACCOUNTADMIN", days_back=200)
        self.grant("USAGE", "DATABASE_ROLE", "SNOWFLAKE.SECURITY_VIEWER", "HUGO_ROLE", granted_by="ACCOUNTADMIN", days_back=90)
        self.grant("USAGE", "DATABASE_ROLE", "SNOWFLAKE.OBJECT_VIEWER", "PUBLIC", granted_by="ACCOUNTADMIN", days_back=60)
        self.grant("READ", "SECRET", "SEC_API_KEY", "PUBLIC", schema_="SECRETS", catalog="SEC_DB")
        self.grant("OWNERSHIP", "SECRET", "SEC_DB_PW", "ACCOUNTADMIN", schema_="SECRETS", catalog="SEC_DB")
        self.grant("OWNERSHIP", "INTEGRATION", "S3_INT", "ACCOUNTADMIN")
        # role -> user grants
        ug = [("ADMIN_ALICE", "ACCOUNTADMIN"), ("ADMIN_BOB", "ACCOUNTADMIN"), ("ADMIN_BOB", "SECURITYADMIN"),
              ("ADMIN_ALICE", "SYSADMIN"), ("ANALYST_CARA", "ANALYST_ROLE"), ("ANALYST_DAN", "ANALYST_ROLE"),
              ("ANALYST_EVA", "BI_ROLE"), ("ANALYST_FRANK", "ANALYST_ROLE"), ("DEV_GINA", "DEV_ROLE"),
              ("DEV_HUGO", "DEV_ROLE"), ("DEV_HUGO", "DATA_ADMIN"), ("SVC_ETL", "ETL_ROLE"),
              ("SVC_BI", "BI_ROLE"), ("SVC_LEGACY", "ETL_ROLE"), ("SVC_LEGACY", "SYSADMIN"),
              ("SVC_NOKEY", "DEV_ROLE"), ("DEV_HUGO", "HUGO_ROLE")]
        for u, r in ug:
            self.au("GRANTS_TO_USERS", dict(created_on=_t(self.day(400), 9), role=r, granted_to="USER",
                                            grantee_name=u, granted_by="USERADMIN"))
        self.au("GRANTS_TO_USERS", dict(created_on=_t(self.day(500), 9), deleted_on=_t(self.day(60), 9),
                                        role="DEV_ROLE", granted_to="USER", grantee_name="EX_IVAN",
                                        granted_by="USERADMIN"))
        if self.demo:
            self.demo_users_roles()

    def grant(self, privilege, on, name, grantee, granted_by="SYSADMIN", schema_="", catalog="",
              option=False, deleted=False, days_back=None) -> None:
        # days_back skips the random draw, so a new grant doesn't shift the rest of the fake data
        back = days_back if days_back is not None else self.rng.randint(30, 700)
        if self.demo and catalog:
            name = name.split(".")[-1]                      # NAME is the object's own name; its parents are columns
            if on == "SCHEMA":
                schema_ = ""                                 # a schema grant names its database only
        self.au("GRANTS_TO_ROLES", dict(
            created_on=_t(self.day(back), 9), modified_on=_t(self.day(20), 9),
            deleted_on=_t(self.day(15), 9) if deleted else None, privilege=privilege, granted_on=on,
            name=name, table_catalog=catalog or None, table_schema=schema_ or None,
            granted_to="ROLE", grantee_name=grantee, grant_option=option, granted_by=granted_by,
            granted_by_role_type="ROLE", object_instance=None))

    # ---- databases, schemas, tables ---------------------------------------------------------------
    def objects(self) -> None:
        dbs = [(101, "RAW_DB", "SYSADMIN", "NO", 1), (102, "ANALYTICS_DB", "SYSADMIN", "NO", 7),
               (103, "SANDBOX_DB", "DEV_ROLE", "NO", 1), (104, "DEV_DB", "DEV_ROLE", "YES", 0)]
        self.dbs = {n: i for i, n, *_ in dbs}
        for i, n, owner, trans, ret in dbs:
            self.au("DATABASES", dict(database_id=i, database_name=n, database_owner=owner, is_transient=trans,
                                      type="STANDARD", retention_time=ret, created=_t(self.day(600), 9),
                                      last_altered=_t(self.day(20), 9), owner_role_type="ROLE",
                                      object_visibility="PRIVILEGED"))
        self.au("DATABASES", dict(database_id=105, database_name="OLD_DB", database_owner="SYSADMIN",
                                  is_transient="NO", type="STANDARD", retention_time=1,
                                  created=_t(self.day(700), 9), last_altered=_t(self.day(90), 9),
                                  deleted=_t(self.day(40), 9), owner_role_type="ROLE"))
        self.au("DATABASES", dict(database_id=106, database_name="SNOWFLAKE_SAMPLE_DATA", database_owner=None,
                                  is_transient="NO", type="IMPORTED DATABASE", retention_time=0,
                                  created=_t(self.day(600), 9)))
        schemas = {"RAW_DB": ["LANDING", "STAGING", "PUBLIC"], "ANALYTICS_DB": ["CORE", "MARTS", "PUBLIC"],
                   "SANDBOX_DB": ["SCRATCH", "PUBLIC"], "DEV_DB": ["PUBLIC", "FEATURE_X"]}
        self.schema_id = {}
        sid = 200
        for db, names in schemas.items():
            for n in names + ["INFORMATION_SCHEMA"]:
                sid += 1
                self.schema_id[(db, n)] = sid
                managed = "YES" if n in ("CORE", "MARTS") else "NO"
                owner = {"LANDING": "ETL_ROLE", "MARTS": "DATA_ADMIN", "SCRATCH": "DEV_ROLE",
                         "FEATURE_X": "DEV_ROLE"}.get(n, "SYSADMIN")
                self.au("SCHEMATA", dict(schema_id=sid, schema_name=n, catalog_id=self.dbs[db],
                                         catalog_name=db, schema_owner=None if n == "INFORMATION_SCHEMA" else owner,
                                         retention_time=1, is_transient="YES" if db == "DEV_DB" else "NO",
                                         is_managed_access=managed, created=_t(self.day(500), 9),
                                         last_altered=_t(self.day(30), 9), owner_role_type="ROLE"))
        self.au("SCHEMATA", dict(schema_id=299, schema_name="OLD_SCHEMA", catalog_id=101, catalog_name="RAW_DB",
                                 schema_owner="SYSADMIN", retention_time=1, is_transient="NO",
                                 is_managed_access="NO", created=_t(self.day(500), 9),
                                 deleted=_t(self.day(60), 9), owner_role_type="ROLE"))
        # db, schema, name, table_type, transient, rows, gb, clustered, dynamic, hybrid, iceberg,
        # created_days, altered_days, retention, owner, tt_gb, fs_gb
        T = [
            ("RAW_DB", "LANDING", "ORDERS_RAW", "BASE TABLE", "NO", 900_000_000, 420, "", "NO", "NO", "NO", 500, 1, 1, "ETL_ROLE", 30, 90),
            ("RAW_DB", "LANDING", "CUSTOMERS_RAW", "BASE TABLE", "NO", 20_000_000, 8, "", "NO", "NO", "NO", 500, 1, 1, "ETL_ROLE", 1, 3),
            ("RAW_DB", "LANDING", "EVENTS_RAW", "BASE TABLE", "NO", 3_000_000_000, 900, "(EVENT_DATE)", "NO", "NO", "NO", 400, 200, 1, "ETL_ROLE", 5, 200),
            ("RAW_DB", "STAGING", "ORDERS_STG", "BASE TABLE", "NO", 5_000_000, 3, "", "NO", "NO", "NO", 300, 1, 1, "ETL_ROLE", 2, 500),
            ("RAW_DB", "STAGING", "CUSTOMERS_STG", "BASE TABLE", "YES", 2_000_000, 1, "", "NO", "NO", "NO", 300, 1, 0, "ETL_ROLE", 0, 0),
            ("RAW_DB", "PUBLIC", "LOOKUP_COUNTRY", "BASE TABLE", "NO", 250, 0.001, "", "NO", "NO", "NO", 600, 400, 1, "SYSADMIN", 0, 0),
            ("ANALYTICS_DB", "CORE", "ORDERS", "BASE TABLE", "NO", 850_000_000, 380, "(ORDER_DATE, REGION)", "NO", "NO", "NO", 480, 1, 7, "SYSADMIN", 60, 200),
            ("ANALYTICS_DB", "CORE", "CUSTOMERS", "BASE TABLE", "NO", 19_000_000, 7, "", "NO", "NO", "NO", 480, 1, 7, "SYSADMIN", 12, 12),
            ("ANALYTICS_DB", "CORE", "PRODUCTS", "BASE TABLE", "NO", 40_000, 0.05, "", "NO", "NO", "NO", 480, 60, 7, "SYSADMIN", 0, 0),
            ("ANALYTICS_DB", "CORE", "ORDERS_CLONE", "BASE TABLE", "NO", 850_000_000, 380, "", "NO", "NO", "NO", 90, 90, 1, "SYSADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "DAILY_SALES", "BASE TABLE", "NO", 400_000, 0.4, "", "YES", "NO", "NO", 200, 0, 1, "DATA_ADMIN", 0, 1),
            ("ANALYTICS_DB", "MARTS", "CUSTOMER_LTV", "BASE TABLE", "NO", 19_000_000, 5, "", "YES", "NO", "NO", 200, 0, 1, "DATA_ADMIN", 1, 2),
            ("ANALYTICS_DB", "MARTS", "SESSION_STATE", "BASE TABLE", "NO", 100_000, 0.2, "", "NO", "YES", "NO", 100, 0, 1, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "ICE_EVENTS", "BASE TABLE", "NO", 50_000_000, 30, "", "NO", "NO", "YES", 150, 3, 1, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "EXT_ORDERS", "EXTERNAL TABLE", "NO", None, None, "", "NO", "NO", "NO", 150, 3, 0, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "SALES_MV", "MATERIALIZED VIEW", "NO", 400_000, 0.3, "", "NO", "NO", "NO", 120, 2, 1, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "V_ORDERS", "VIEW", "NO", None, None, "", "NO", "NO", "NO", 300, 5, 0, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "V_CUSTOMERS", "VIEW", "NO", None, None, "", "NO", "NO", "NO", 300, 5, 0, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "MARTS", "V_BROKEN", "VIEW", "NO", None, None, "", "NO", "NO", "NO", 300, 80, 0, "DATA_ADMIN", 0, 0),
            ("ANALYTICS_DB", "PUBLIC", "T_UNUSED_1", "BASE TABLE", "NO", 100_000_000, 200, "", "NO", "NO", "NO", 700, 400, 1, "SYSADMIN", 10, 40),
            ("SANDBOX_DB", "SCRATCH", "TMP_A", "BASE TABLE", "NO", 1_000_000, 0.5, "", "NO", "NO", "NO", 60, 10, 1, "DEV_ROLE", 0, 1),
            ("SANDBOX_DB", "SCRATCH", "OLD_EXPORT", "BASE TABLE", "NO", 60_000_000, 25, "", "NO", "NO", "NO", 500, 300, 1, "DEV_ROLE", 0, 4),
            ("DEV_DB", "PUBLIC", "TEST_TABLE", "BASE TABLE", "YES", 10_000, 0.01, "", "NO", "NO", "NO", 50, 2, 0, "DEV_ROLE", 0, 0),
            ("DEV_DB", "FEATURE_X", "FX_FEATURES", "BASE TABLE", "YES", 500_000, 0.2, "", "NO", "NO", "NO", 30, 1, 0, "DEV_ROLE", 0, 0),
        ]
        self.tables = []
        tid = 5000
        GB = 1024 ** 3
        for db, sch, name, ttype, trans, rows, gb, ck, dyn, hyb, ice, cdays, adays, ret, owner, ttgb, fsgb in T:
            tid += 1
            t = dict(id=tid, db=db, schema=sch, name=name, type=ttype, transient=trans, rows=rows,
                     bytes=None if gb is None else int(gb * GB), clustering=ck, dynamic=dyn, hybrid=hyb,
                     iceberg=ice, owner=owner, fqn=f"{db}.{sch}.{name}")
            self.tables.append(t)
            self.au("TABLES", dict(
                table_id=tid, table_name=name, table_schema_id=self.schema_id[(db, sch)], table_schema=sch,
                table_catalog_id=self.dbs[db], table_catalog=db, table_owner=owner, table_type=ttype,
                is_transient=trans, clustering_key=ck or None, auto_clustering_on="YES" if ck else "NO",
                row_count=rows, bytes=t["bytes"], retention_time=ret, created=_t(self.day(cdays), 9),
                last_altered=_t(self.day(adays), 9), last_ddl=_t(self.day(adays), 9), last_ddl_by=owner,
                is_iceberg=ice, is_dynamic=dyn, is_hybrid=hyb))
            if ttype == "BASE TABLE" and not ice == "YES" and not hyb == "YES" or ttype == "BASE TABLE":
                self.au("TABLE_STORAGE_METRICS", dict(
                    id=tid, table_name=name, table_schema_id=self.schema_id[(db, sch)], table_schema=sch,
                    table_catalog_id=self.dbs[db], table_catalog=db, clone_group_id=tid if name != "ORDERS_CLONE" else 5007,
                    is_transient=trans, active_bytes=t["bytes"] if hyb != "YES" and ice != "YES" else 0,
                    time_travel_bytes=int(ttgb * GB), failsafe_bytes=int(fsgb * GB) if trans != "YES" else 0,
                    retained_for_clone_bytes=int(40 * GB) if name == "ORDERS" else 0, deleted=False,
                    table_created=_t(self.day(cdays), 9)))
        # dropped tables still in Fail-safe or Time Travel; names can be NULL
        self.au("TABLE_STORAGE_METRICS", dict(
            id=7001, table_name=None, table_schema_id=self.schema_id[("RAW_DB", "LANDING")], table_schema=None,
            table_catalog_id=101, table_catalog=None, clone_group_id=7001, is_transient="NO", active_bytes=0,
            time_travel_bytes=0, failsafe_bytes=int(120 * GB), retained_for_clone_bytes=int(30 * GB), deleted=True,
            table_created=_t(self.day(300), 9), table_dropped=_t(self.day(6), 9),
            table_entered_failsafe=_t(self.day(5), 9)))
        for k in range(6):                      # the same name dropped again and again
            self.au("TABLE_STORAGE_METRICS", dict(
                id=7010 + k, table_name="TMP_LOAD", table_schema_id=self.schema_id[("RAW_DB", "STAGING")],
                table_schema="STAGING", table_catalog_id=101, table_catalog="RAW_DB", clone_group_id=7010 + k,
                is_transient="NO", active_bytes=0, time_travel_bytes=0, failsafe_bytes=int(3 * GB),
                retained_for_clone_bytes=0, deleted=True, table_created=_t(self.day(30 + k), 9),
                table_dropped=_t(self.day(2 + k), 9), table_entered_failsafe=_t(self.day(1 + k), 9)))
        self.au("TABLE_STORAGE_METRICS", dict(
            id=7002, table_name="OLD_FACTS", table_schema_id=self.schema_id[("RAW_DB", "STAGING")],
            table_schema="STAGING", table_catalog_id=101, table_catalog="RAW_DB", clone_group_id=7002,
            is_transient="NO", active_bytes=0, time_travel_bytes=0, failsafe_bytes=int(60 * GB),
            retained_for_clone_bytes=0, deleted=True, table_created=_t(self.day(300), 9),
            table_dropped=_t(self.day(4), 9), table_entered_failsafe=_t(self.day(3), 9)))
        self.au("TABLE_STORAGE_METRICS", dict(
            id=7003, table_name="ORPHAN_TMP", table_schema_id=299, table_schema="OLD_SCHEMA", table_catalog_id=101,
            table_catalog="RAW_DB", clone_group_id=7003, is_transient="NO", active_bytes=int(2 * GB),
            time_travel_bytes=0, failsafe_bytes=int(8 * GB), retained_for_clone_bytes=0, deleted=False,
            table_created=_t(self.day(300), 9), schema_dropped=_t(self.day(60), 9)))
        for t in self.tables:
            if t["type"] in ("VIEW", "MATERIALIZED VIEW"):
                self.au("VIEWS", dict(
                    table_id=t["id"], table_name=t["name"], table_schema_id=self.schema_id[(t["db"], t["schema"])],
                    table_schema=t["schema"], table_catalog_id=self.dbs[t["db"]], table_catalog=t["db"],
                    table_owner=t["owner"], view_definition="select 1", is_updatable="NO", insertable_into="NO",
                    is_secure="YES" if t["name"] == "V_CUSTOMERS" else "NO", created=_t(self.day(300), 9),
                    last_altered=_t(self.day(5), 9), last_ddl=_t(self.day(5), 9), last_ddl_by=t["owner"],
                    owner_role_type="ROLE"))
        # dependencies: views on tables; V_BROKEN references a dropped table
        by = {t["name"]: t for t in self.tables}
        edges = [("V_ORDERS", "ORDERS"), ("V_CUSTOMERS", "CUSTOMERS"), ("SALES_MV", "ORDERS"),
                 ("DAILY_SALES", "ORDERS"), ("CUSTOMER_LTV", "CUSTOMERS"), ("V_BROKEN", "GONE_TABLE")]
        for a, b in edges:
            src = by.get(b)
            self.au("OBJECT_DEPENDENCIES", dict(
                referenced_database="ANALYTICS_DB" if src else "RAW_DB", referenced_schema="CORE" if src else "STAGING",
                referenced_object_name=b, referenced_object_id=src["id"] if src else 7999,
                referenced_object_domain="TABLE", referencing_database="ANALYTICS_DB", referencing_schema="MARTS",
                referencing_object_name=a, referencing_object_id=by[a]["id"],
                referencing_object_domain="VIEW" if a.startswith("V_") else "TABLE", dependency_type="BY_ID"))
        # functions, procedures, stages, file formats, sequences
        for i, (n, lang, ext) in enumerate([("F_CLEAN", "SQL", "NO"), ("F_SCORE", "PYTHON", "NO"),
                                            ("F_EXT_LOOKUP", "PYTHON", "YES")]):
            self.au("FUNCTIONS", dict(
                function_id=8100 + i, function_name=n, function_schema_id=self.schema_id[("ANALYTICS_DB", "CORE")],
                function_schema="CORE", function_catalog_id=102, function_catalog="ANALYTICS_DB",
                function_owner="SYSADMIN", argument_signature="(V VARCHAR)", data_type="VARCHAR",
                function_language=lang, is_external="NO", api_integration=None,
                runtime_version="3.10" if lang == "PYTHON" else None,
                external_access_integrations="[EXT_INT]" if ext == "YES" else None,
                created=_t(self.day(200), 9), last_altered=_t(self.day(20), 9)))
        for i, (n, lang) in enumerate([("P_LOAD", "SQL"), ("P_REFRESH", "PYTHON")]):
            self.au("PROCEDURES", dict(
                procedure_catalog_id=102, procedure_catalog="ANALYTICS_DB",
                procedure_schema_id=self.schema_id[("ANALYTICS_DB", "CORE")], procedure_schema="CORE",
                procedure_name=n, procedure_owner="SYSADMIN", argument_signature="()", procedure_language=lang,
                runtime_version="3.10" if lang == "PYTHON" else None, created=_t(self.day(200), 9),
                last_altered=_t(self.day(20), 9)))
        stages = [("S3_LANDING", "External Named", "s3://fake-bucket/landing/", "S3_INT"),
                  ("S3_ARCHIVE", "External Named", "s3://fake-bucket/archive/", None),
                  ("INT_LOAD", "Internal Named", None, None)]
        for i, (n, typ, url, integ) in enumerate(stages):
            self.au("STAGES", dict(
                stage_id=8200 + i, stage_name=n, stage_schema_id=self.schema_id[("RAW_DB", "LANDING")],
                stage_schema="LANDING", stage_catalog_id=101, stage_catalog="RAW_DB", stage_url=url,
                stage_region="us-east-1" if url else None, stage_type=typ, stage_owner="ETL_ROLE",
                created=_t(self.day(300), 9), last_altered=_t(self.day(30), 9), owner_role_type="ROLE",
                storage_integration=integ))
        for i, (n, typ) in enumerate([("FF_CSV", "CSV"), ("FF_JSON", "JSON")]):
            self.au("FILE_FORMATS", dict(
                file_format_id=8300 + i, file_format_name=n, file_format_schema_id=self.schema_id[("RAW_DB", "LANDING")],
                file_format_schema="LANDING", file_format_catalog_id=101, file_format_catalog="RAW_DB",
                file_format_type=typ, file_format_owner="ETL_ROLE", created=_t(self.day(300), 9)))
        for t in self.tables:
            if t["type"] in ("BASE TABLE", "EXTERNAL TABLE"):
                owner = "HUGO_ROLE" if t["name"] in ("TMP_A", "OLD_EXPORT", "TEST_TABLE") else t["owner"]
                self.grant("OWNERSHIP", "TABLE", t["fqn"], owner, schema_=t["schema"], catalog=t["db"])
        self.au("SEQUENCES", dict(
            sequence_id=8400, sequence_name="SEQ_ORDERS", sequence_schema_id=self.schema_id[("ANALYTICS_DB", "CORE")],
            sequence_schema="CORE", sequence_catalog_id=102, sequence_catalog="ANALYTICS_DB",
            sequence_owner="SYSADMIN", data_type="NUMBER", start_value=1, next_value=900_000_000_001,
            increment="1", ordered="NO", created=_t(self.day(300), 9)))
        if self.demo:
            self.demo_objects()

    # ---- queries -------------------------------------------------------------------------------------
    def queries(self) -> None:
        rng = self.rng
        self.q_rows = []       # kept for attribution, access history and metering
        profiles = {
            "WH_ETL": dict(n=(10, 18), hours=(1, 5), users=["SVC_ETL", "SVC_LEGACY"], role="ETL_ROLE",
                           types=["COPY", "INSERT", "MERGE", "CREATE_TABLE_AS_SELECT", "SELECT", "UPDATE", "UNLOAD"],
                           tag=["airflow:dag_orders", "airflow:dag_customers", "dbt"], db="ANALYTICS_DB",
                           dur=(20, 900), weekend=True),
            "WH_BI": dict(n=(30, 60), hours=(8, 18), users=["ANALYST_EVA", "SVC_BI", "ANALYST_DAN", "ANALYST_CARA"],
                          role="BI_ROLE", types=["SELECT"] * 9 + ["SHOW", "DESCRIBE"],
                          tag=["bi:tableau:sales_dash", "bi:tableau:ops_dash", "bi:looker:finance", ""],
                          db="ANALYTICS_DB", dur=(0.3, 40), weekend=False),
            "WH_ADHOC": dict(n=(8, 20), hours=(7, 20), users=["ADMIN_BOB", "ANALYST_CARA", "DEV_HUGO", "ANALYST_FRANK",
                                                              "ADMIN_ALICE"],
                             role="ANALYST_ROLE", types=["SELECT"] * 6 + ["SHOW", "DESCRIBE", "USE", "CREATE_TABLE"],
                             tag=[""], db="SANDBOX_DB", dur=(0.2, 200), weekend=True),
            "WH_IDLE": dict(n=(0, 1), hours=(9, 10), users=["DEV_HUGO"], role="DEV_ROLE", types=["SELECT"],
                            tag=[""], db="DEV_DB", dur=(0.5, 3), weekend=False),
            "WH_ADAPTIVE": dict(n=(6, 14), hours=(6, 22), users=["ANALYST_DAN", "SVC_BI", "ANALYST_CARA"],
                                role="ANALYST_ROLE", types=["SELECT"] * 5 + ["INSERT"], tag=["", "bi:looker:finance"],
                                db="ANALYTICS_DB", dur=(0.5, 60), weekend=True),
            "WH_ML": dict(n=(2, 6), hours=(9, 17), users=["DEV_HUGO", "ADMIN_ALICE"], role="DATA_ADMIN",
                          types=["SELECT", "CALL", "CREATE_TABLE_AS_SELECT"], tag=["ml:train", ""],
                          db="ANALYTICS_DB", dur=(60, 1800), weekend=True),
        }
        tables_by_wh = {"WH_ETL": ["RAW_DB.LANDING.ORDERS_RAW", "RAW_DB.LANDING.CUSTOMERS_RAW",
                                    "ANALYTICS_DB.CORE.ORDERS", "ANALYTICS_DB.CORE.CUSTOMERS"],
                        "WH_BI": ["ANALYTICS_DB.CORE.ORDERS", "ANALYTICS_DB.CORE.CUSTOMERS",
                                  "ANALYTICS_DB.MARTS.DAILY_SALES", "ANALYTICS_DB.MARTS.SALES_MV"]}
        self.sessions = {}
        self.sess_start: dict[tuple, dt.datetime] = {}
        qn = 0
        spike_days = {self.day(k) for k in (3, 12, 27, 41, 66)}
        self.spike_extra = {self.day(k): extra for k, extra in ((3, 60), (12, 35), (27, 60), (41, 35), (66, 35))}
        self._sess_id = 1_000_000
        for d in self.days(QUERY_DAYS):
            for w in self.wh:
                if w["name"] in self.demo_wh_names:
                    continue                                 # the demo's own pass, after the base account
                p = profiles[w["name"]]
                if not p["weekend"] and not self.is_weekday(d):
                    continue
                lo, hi = p["n"]
                n = rng.randint(lo, hi)
                if w["name"] == "WH_ADHOC" and d in spike_days:
                    n += 80                                  # metadata storm: cloud services above 10%
                for _ in range(n):
                    qn += 1
                    row = self._query_row(w, p, d, rng, qn, p["users"], spike_days)
                    if self.demo:                            # the demo keeps one statement shape per warehouse
                        row["query_hash"] = row["query_parameterized_hash"] = f"{row['query_hash']}w{w['id']}"
                    self.q_rows.append(row)
                    self.au("QUERY_HISTORY", row)
        # a few huge result sets, and security-relevant statements by the admins
        for k in range(6):
            r = dict(next(x for x in reversed(self.q_rows) if x["warehouse_name"] == "WH_ADHOC" and x["query_type"] == "SELECT"
                          and x["execution_status"] == "SUCCESS"))
            qn += 1
            r.update(query_id=f"01b-{qn:08d}", rows_produced=80_000_000, bytes_written_to_result=int(6 * 1024 ** 3),
                     user_name="ANALYST_CARA", query_parameterized_hash="hbig", query_hash="hbig",
                     start_time=r["start_time"] - dt.timedelta(days=k), end_time=r["end_time"] - dt.timedelta(days=k))
            self.q_rows.append(r)
            self.au("QUERY_HISTORY", r)
        admin_sql = [("ALTER USER ANALYST_CARA SET MINS_TO_BYPASS_MFA = 30", "ALTER_USER", "ADMIN_BOB", "SECURITYADMIN"),
                     ("ALTER ACCOUNT UNSET NETWORK_POLICY", "ALTER_ACCOUNT", "ADMIN_BOB", "ACCOUNTADMIN"),
                     ("CREATE NETWORK POLICY NP_X ALLOWED_IP_LIST = ('0.0.0.0/0')", "CREATE_NETWORK_POLICY", "ADMIN_ALICE", "SECURITYADMIN"),
                     ("GRANT ROLE ACCOUNTADMIN TO USER DEV_HUGO", "GRANT", "ADMIN_ALICE", "SECURITYADMIN"),
                     ("CREATE USER NEW_USER PASSWORD = 'x'", "CREATE_USER", "ADMIN_ALICE", "USERADMIN"),
                     ("ALTER USER DEV_HUGO SET PASSWORD = 'y'", "ALTER_USER", "ADMIN_BOB", "SECURITYADMIN"),
                     ("CREATE MASKING POLICY MP AS (V STRING) RETURNS STRING -> V", "CREATE_MASKING_POLICY", "ADMIN_ALICE", "ACCOUNTADMIN"),
                     ("ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS = 3600", "ALTER_ACCOUNT", "ADMIN_ALICE", "ACCOUNTADMIN"),
                     ("CREATE SECURITY INTEGRATION SI TYPE = SAML2", "CREATE_INTEGRATION", "ADMIN_ALICE", "ACCOUNTADMIN"),
                     ("DROP ROLE OLD_ROLE", "DROP_ROLE", "ADMIN_BOB", "SECURITYADMIN")]
        for k, (text, qtype, user, role) in enumerate(admin_sql):
            qn += 1
            d = self.day(2 + k * 5)
            start = _t(d, 11, 5)
            row = dict(query_id=f"01b-{qn:08d}", query_text=text, query_type=qtype, user_name=user, role_name=role,
                       warehouse_id=1003, warehouse_name="WH_ADHOC", warehouse_size="Small", warehouse_type="STANDARD",
                       execution_status="SUCCESS", start_time=start, end_time=start + dt.timedelta(seconds=1),
                       total_elapsed_time=900, compilation_time=100, execution_time=800, bytes_scanned=0,
                       credits_used_cloud_services=0.0004, query_hash="hadm", query_parameterized_hash="hadm",
                       role_type="ROLE", user_type="PERSON")
            self.q_rows.append(row)
            self.au("QUERY_HISTORY", row)
        self.qn = qn
        # eligible for acceleration: a few long selects on WH_BI and WH_ADHOC
        for r in self.q_rows:
            if r["query_type"] == "SELECT" and r["warehouse_name"] in ("WH_BI", "WH_ADHOC") \
                    and r["execution_time"] > 60000 and rng.random() < 0.7:
                self.au("QUERY_ACCELERATION_ELIGIBLE", dict(
                    query_id=r["query_id"], query_text=r["query_text"], start_time=r["start_time"],
                    end_time=r["end_time"], warehouse_name=r["warehouse_name"], warehouse_size=r["warehouse_size"],
                    eligible_query_acceleration_time=r["execution_time"] / 1000 * 0.6, upper_limit_scale_factor=8,
                    query_hash=r["query_hash"], query_hash_version=2,
                    query_parameterized_hash=r["query_parameterized_hash"], query_parameterized_hash_version=1))
        if self.demo:
            self.demo_queries(profiles, spike_days)

    def _query_row(self, w, p, d, rng, qn, users, spike_days) -> dict:
        """One QUERY_HISTORY row on warehouse `w` with profile `p`; every draw comes from `rng`."""
        like = w.get("like", w["name"])                  # a demo warehouse behaves like a base one
        user = rng.choice(users)
        qtype = rng.choice(p["types"])
        hour = rng.randint(*p["hours"]) if p["hours"][1] > p["hours"][0] else p["hours"][0]
        start = _t(d, hour, rng.randint(0, 59), rng.randint(0, 59))
        dur = rng.uniform(*p["dur"])
        if rng.random() < 0.04:
            dur *= 8                             # a long one
        if qtype in ("SHOW", "DESCRIBE", "USE"):
            dur = rng.uniform(0.05, 0.4)
        comp_ms = int(rng.uniform(30, 800) * (5 if rng.random() < 0.03 else 1))
        queue_p = 0.15 if w["name"] == "WH_BI" else w.get("queue", 0)
        queued_over = int(rng.uniform(500, 30000)) if (queue_p and rng.random() < queue_p) else 0
        queued_prov = int(rng.uniform(200, 2000)) if rng.random() < 0.05 else 0
        exec_ms = int(dur * 1000)
        total = comp_ms + exec_ms + queued_over + queued_prov
        end = start + dt.timedelta(milliseconds=total)
        fail = rng.random() < w.get("fail", 0.10 if like == "WH_ADHOC" else 0.03)
        status = "FAIL" if fail else "SUCCESS"
        err, msg = None, None
        if fail:
            err, msg = rng.choice([(1003, "SQL compilation error: syntax error"),
                                   (2003, "Object does not exist or not authorized"),
                                   (100051, "Division by zero"),
                                   (604, "Statement reached its statement or warehouse timeout")])
        big = like in ("WH_ETL", "WH_ML") or rng.random() < 0.05
        scanned = int(rng.uniform(1e6, 5e9) * (20 if big else 1)) if qtype not in ("SHOW", "DESCRIBE", "USE") else 0
        spill_local = int(scanned * rng.uniform(0.05, 0.6)) if (big and rng.random() < w.get("spill", 0.15)) else 0
        spill_remote = int(scanned * rng.uniform(0.02, 0.3)) if (spill_local and rng.random() < 0.5) else 0
        ptotal = int(rng.uniform(200, 20000)) if scanned else None
        pscanned = None if not scanned else int(ptotal * (rng.uniform(0.85, 1.0) if rng.random() < 0.35 else rng.uniform(0.01, 0.4)))
        cs = rng.uniform(0.00002, 0.0009)
        if qtype in ("SHOW", "DESCRIBE", "USE") and w["name"] == "WH_ADHOC":
            cs = rng.uniform(0.0004, 0.004) * (45 if d in spike_days else 1)
        key = (user, d, w["name"])
        if key not in self.sessions:
            self._sess_id += 1
            self.sessions[key] = self._sess_id
        sid = self.sessions[key]
        if key not in self.sess_start or start < self.sess_start[key]:
            self.sess_start[key] = start               # the session opened just before its first statement
        tag = rng.choice(p["tag"])
        if user == "ANALYST_FRANK" and qn % 5 == 0:
            tag = "crosshire-audit"  # the export's own statements, for cost_audit_self_usage
        if tag == "dbt":
            m = rng.randint(1, 12)
            tag = ('{"app":"dbt","node_id":"model.shop.m%d","invocation_id":"inv%d","project_name":"shop",'
                   '"target_name":"prod","materialized":"%s"}' % (m, d.toordinal() % 50,
                                                                  rng.choice(["table", "incremental", "view"])))
        role = p.get("role_of", {}).get(user, p["role"])
        if user in ("ADMIN_BOB", "ADMIN_ALICE") and rng.random() < 0.6:
            role = "ACCOUNTADMIN"
        if user == "SVC_LEGACY" and rng.random() < 0.3:
            role = "SYSADMIN"
        db = p["db"]
        schema_name = p.get("schema") or {"ANALYTICS_DB": "MARTS", "RAW_DB": "LANDING", "SANDBOX_DB": "SCRATCH",
                                          "DEV_DB": "PUBLIC"}[db]
        text = self.query_text(w["name"], qtype, tag, rng)
        qhash = f"h{(qn * 7) % 97:03d}" if qtype == "SELECT" else f"h{(qn * 13) % 41:03d}"
        cluster = rng.randint(1, w["max"]) if w["max"] > 1 and rng.random() < 0.4 else 1
        row = dict(
            query_id=f"01b-{qn:08d}", query_text=text, database_id=self.dbs[db], database_name=db,
            schema_id=self.schema_id[(db, schema_name)], schema_name=schema_name, query_type=qtype,
            session_id=sid, user_name=user, role_name=role, warehouse_id=w["id"], warehouse_name=w["name"],
            warehouse_size=self.size_at(w, start), warehouse_type=w["type"], cluster_number=cluster, query_tag=tag or None,
            execution_status=status, error_code=err, error_message=msg, start_time=start, end_time=end,
            total_elapsed_time=total, compilation_time=comp_ms, execution_time=exec_ms,
            queued_provisioning_time=queued_prov, queued_repair_time=0, queued_overload_time=queued_over,
            transaction_blocked_time=int(rng.uniform(1000, 60000)) if rng.random() < 0.01 else 0,
            child_queries_wait_time=0, query_retry_time=0, fault_handling_time=0,
            bytes_scanned=scanned, percentage_scanned_from_cache=round(rng.uniform(0, 100) if rng.random() < 0.7 else 0, 2),
            bytes_written=int(scanned * 0.05) if qtype in ("INSERT", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "UPDATE") else 0,
            bytes_written_to_result=int(rng.uniform(1e3, 1e7)) if qtype == "SELECT" else 0,
            bytes_read_from_result=0, rows_produced=int(rng.uniform(1, 1e6)) if scanned else 0,
            rows_inserted=int(rng.uniform(1e3, 1e7)) if qtype in ("INSERT", "COPY", "MERGE") else 0,
            rows_updated=0, rows_deleted=0, rows_unloaded=0, bytes_deleted=0,
            partitions_scanned=pscanned, partitions_total=ptotal,
            bytes_spilled_to_local_storage=spill_local, bytes_spilled_to_remote_storage=spill_remote,
            bytes_sent_over_the_network=int(scanned * 0.01),
            credits_used_cloud_services=cs, query_load_percent=int(rng.uniform(5, 100)),
            query_acceleration_bytes_scanned=0, query_acceleration_partitions_scanned=0,
            query_hash=qhash, query_hash_version=2, query_parameterized_hash=qhash, query_parameterized_hash_version=1,
            transaction_id=qn, role_type="ROLE", user_type=self.user_type(user),
            secondary_role_stats='{"roles":["DATA_ADMIN"]}' if user == "DEV_HUGO" else None,
            is_client_generated_statement=False, user_database_id=str(self.dbs[db]),
            user_schema_id=str(self.schema_id[(db, schema_name)]))
        if w["name"] == "WH_BI" and rng.random() < 0.08:
            row["query_acceleration_bytes_scanned"] = int(scanned * 0.4)
            row["query_acceleration_partitions_scanned"] = 50
        if w["name"] == "WH_BI" and rng.random() < 0.02:
            row["outbound_data_transfer_cloud"] = "AWS"
            row["outbound_data_transfer_region"] = "AWS_US_WEST_2"
            row["outbound_data_transfer_bytes"] = int(rng.uniform(1e9, 8e10))
        if qtype in ("COPY", "UNLOAD") and rng.random() < 0.5:
            row["outbound_data_transfer_cloud"] = "AWS"
            row["outbound_data_transfer_region"] = "AWS_EU_WEST_1"
            row["outbound_data_transfer_bytes"] = int(rng.uniform(1e9, 2e11))
        return row

    def synthetic_query(self, query_id, wh_name, start, seconds, role, qtype, status="SUCCESS", db="ANALYTICS_DB",
                        schema_name="MARTS"):
        """A statement run by the system for a task or a dynamic table, so history views can join to it."""
        w = self.wh_by_name[wh_name]
        ms = int(seconds * 1000)
        qhash = f"hsys{w['id']}" if self.demo else "hsys"   # the demo keeps one statement shape per warehouse
        row = dict(
            query_id=query_id, query_text=f"{qtype.lower()} 1", database_id=self.dbs[db], database_name=db,
            schema_id=self.schema_id[(db, schema_name)], schema_name=schema_name, query_type=qtype,
            user_name="SYSTEM", role_name=role, warehouse_id=w["id"], warehouse_name=w["name"],
            warehouse_size=self.size_at(w, start), warehouse_type=w["type"], cluster_number=1, execution_status=status,
            start_time=start, end_time=start + dt.timedelta(milliseconds=ms), total_elapsed_time=ms + 200,
            compilation_time=200, execution_time=ms, queued_provisioning_time=0, queued_overload_time=0,
            bytes_scanned=int(seconds * 5e7), partitions_scanned=100, partitions_total=400,
            query_tag=None, credits_used_cloud_services=0.0002, query_hash=qhash, query_parameterized_hash=qhash,
            role_type="ROLE", user_type="PERSON")
        self.q_rows.append(row)
        self.au("QUERY_HISTORY", row)

    def user_type(self, user: str) -> str:
        return "SERVICE" if user.startswith("SVC_") else "PERSON"

    def query_text(self, wh: str, qtype: str, tag: str, rng) -> str:
        # Comments only, no literals: the checks that parse query text look at these markers.
        if tag.startswith("{"):
            return f'/* {{"app": "dbt", "node_id": "model.shop.m{rng.randint(1, 12)}"}} */ insert into t select 1'
        if tag.startswith("bi:tableau"):
            return f"/* Tableau workbook={tag.split(':')[2]} */ select 1"
        if tag.startswith("bi:looker"):
            return f"/* Looker Query Context '{{\"dashboard_id\":\"{tag.split(':')[2]}\"}}' */ select 1"
        return f"{qtype.lower()} 1"

    # ---- metering ---------------------------------------------------------------------------------
    def metering(self) -> None:
        rng = self.rng
        wh_by_id = {w["id"]: w for w in self.wh}
        # attributed credits per query, and per (warehouse, hour)
        attr_by_hour: dict[tuple[int, dt.datetime], float] = {}
        cs_by_hour: dict[tuple[int, dt.datetime], float] = {}
        for r in self.q_rows:
            w = wh_by_id[r["warehouse_id"]]
            hour = r["start_time"].replace(minute=0, second=0, microsecond=0)
            key = (w["id"], hour)
            cs_by_hour[key] = cs_by_hour.get(key, 0) + r["credits_used_cloud_services"]
            if r["query_type"] in ("SHOW", "DESCRIBE", "USE") or r["execution_time"] < 100:
                continue
            credits = r["execution_time"] / 3600000 * RATE[self.size_at(w, r["start_time"])] * (1 if w["max"] == 1 else 1.5)
            if w["attributed"]:
                attr_by_hour[key] = attr_by_hour.get(key, 0) + credits
                self.au("QUERY_ATTRIBUTION_HISTORY", dict(
                    query_id=r["query_id"], parent_query_id=None, root_query_id=r["query_id"], warehouse_id=w["id"],
                    warehouse_name=w["name"], query_hash=r["query_hash"], query_parameterized_hash=r["query_parameterized_hash"],
                    query_tag=r.get("query_tag"), user_name=r["user_name"], start_time=r["start_time"], end_time=r["end_time"],
                    credits_attributed_compute=credits,
                    credits_used_query_acceleration=None))
            else:
                attr_by_hour[key] = attr_by_hour.get(key, 0) + credits
        idle_pattern = {"WH_ETL": 0.35, "WH_BI": 0.5, "WH_ADHOC": 1.0, "WH_IDLE": 1.0, "WH_ADAPTIVE": 0.25,
                        "WH_ML": 0.3}
        daily: dict[dt.date, dict[str, float]] = {}
        hist_days = self.days(HISTORY_DAYS)
        wh_hours_on = {"WH_ETL": range(0, 7), "WH_BI": range(7, 19), "WH_ADHOC": range(0, 24),
                       "WH_IDLE": range(0, 24), "WH_ADAPTIVE": range(6, 23), "WH_ML": range(9, 18)}
        cs_day = {}
        for d in hist_days:
            for w in self.wh:
                like = w.get("like", w["name"])
                if not self.wh_alive(w, d):
                    continue
                hours_on = self.demo_hours_on(w) if "like" in w else wh_hours_on[w["name"]]
                for h in range(24):
                    hour = _t(d, h)
                    key = (w["id"], hour)
                    attributed = attr_by_hour.get(key, 0)
                    active = h in hours_on
                    if like in ("WH_BI", "WH_ML") and not self.is_weekday(d) and like == "WH_BI":
                        active = False
                    if like == "WH_IDLE":
                        base = RATE[self.size_at(w, hour)] * 0.15            # resumes every hour for nothing
                    elif not active and attributed == 0:
                        continue
                    else:
                        base = 0
                    idle = 0
                    if attributed > 0 or like == "WH_IDLE" or (active and like in ("WH_ETL", "WH_ADHOC", "WH_BI")):
                        idle_full = RATE[self.size_at(w, hour)] * (w["max"] if w["max"] > 1 else 1) * idle_pattern[like]
                        idle = idle_full * (0.5 if attributed else 0.3) if like != "WH_IDLE" else 0
                    if "like" in w:
                        idle = self.demo_idle(w, attributed, active, hour)
                    compute = attributed + idle + base
                    if compute <= 0:
                        continue
                    cs = cs_by_hour.get(key, 0) + (0.004 if like != "WH_IDLE" else 0.001)
                    if "like" in w:
                        cs += compute * w["cs_share"]           # metadata work, a few % of compute
                    if w["name"] == "WH_ADHOC" and h == 10:
                        cs += self.spike_extra.get(d, 0)             # a metadata storm: cloud services above 10% of compute
                    self.au("WAREHOUSE_METERING_HISTORY", dict(
                        start_time=hour, end_time=hour + dt.timedelta(hours=1), warehouse_id=w["id"],
                        warehouse_name=w["name"], credits_used=compute + cs, credits_used_compute=compute,
                        credits_used_cloud_services=cs,
                        credits_attributed_compute_queries=attributed if w["attributed"] else None))
                    self.au("METERING_HISTORY", dict(
                        service_type="WAREHOUSE_METERING", start_time=hour, end_time=hour + dt.timedelta(hours=1),
                        entity_id=w["id"], entity_type="WAREHOUSE", name=w["name"], credits_used_compute=compute,
                        credits_used_cloud_services=cs, credits_used=compute + cs))
                    dd = daily.setdefault(d, {"compute": 0.0, "cs": 0.0})
                    dd["compute"] += compute
                    dd["cs"] += cs
        self.daily_wh = daily
        self.hist_days = hist_days

    # ---- serverless -------------------------------------------------------------------------------
    def serverless(self) -> None:
        rng = self.rng
        svc_daily: dict[tuple[dt.date, str], dict[str, float]] = {}

        def meter(d, service, start, credits, entity_id=None, name=None, entity_type=None, db=None, schema_=None,
                  bytes_=None, rows=None, files=None, cs=0.0):
            self.au("METERING_HISTORY", dict(
                service_type=service, start_time=start, end_time=start + dt.timedelta(hours=1), entity_id=entity_id,
                entity_type=entity_type, name=name, database_id=self.dbs.get(db) if db else None, database_name=db,
                schema_name=schema_, credits_used_compute=credits, credits_used_cloud_services=cs,
                credits_used=credits + cs, bytes=bytes_, rows=rows, files=files))
            dd = svc_daily.setdefault((d, service), {"compute": 0.0, "cs": 0.0})
            dd["compute"] += credits
            dd["cs"] += cs

        ids = {t["name"]: t["id"] for t in self.tables}
        for d in self.hist_days:
            # auto clustering on the two clustered tables
            for tname, base in (("ORDERS", 4.0), ("EVENTS_RAW", 9.0)):
                t = next(t for t in self.tables if t["name"] == tname)
                credits = base * rng.uniform(0.6, 1.4)
                hr = _t(d, rng.randint(0, 23))
                self.au("AUTOMATIC_CLUSTERING_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=credits,
                    num_bytes_reclustered=int(credits * 2e10), num_rows_reclustered=int(credits * 5e7),
                    table_id=t["id"], table_name=t["name"], schema_id=self.schema_id[(t["db"], t["schema"])],
                    schema_name=t["schema"], database_id=self.dbs[t["db"]], database_name=t["db"],
                    version="CLASSIC"))
                meter(d, "AUTO_CLUSTERING", hr, credits, t["id"], t["name"], "TABLE", t["db"], t["schema"])
            # materialized view
            credits = 1.2 * rng.uniform(0.5, 1.5)
            hr = _t(d, 3)
            mv = next(t for t in self.tables if t["name"] == "SALES_MV")
            self.au("MATERIALIZED_VIEW_REFRESH_HISTORY", dict(
                start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=round(credits, 6), table_id=mv["id"],
                table_name=mv["name"], schema_id=self.schema_id[(mv["db"], mv["schema"])], schema_name=mv["schema"],
                database_id=102, database_name="ANALYTICS_DB"))
            meter(d, "MATERIALIZED_VIEW", hr, credits, mv["id"], mv["name"], "TABLE", "ANALYTICS_DB", "MARTS")
            # search optimization
            if rng.random() < 0.8:
                t = next(t for t in self.tables if t["name"] == "CUSTOMERS")
                credits = 0.6 * rng.uniform(0.5, 1.5)
                hr = _t(d, 5)
                self.au("SEARCH_OPTIMIZATION_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=credits, index_id=t["id"] * 10,
                    index_name="SOS_CUST", index_type="Search Optimization Index", base_table_id=t["id"],
                    base_table_name=t["name"], schema_id=self.schema_id[(t["db"], t["schema"])], schema_name=t["schema"],
                    database_id=102, database_name="ANALYTICS_DB"))
                meter(d, "SEARCH_OPTIMIZATION", hr, credits, t["id"], t["name"], "TABLE", "ANALYTICS_DB", "CORE")
            # query acceleration on WH_BI
            if rng.random() < 0.6:
                credits = 0.8 * rng.uniform(0.3, 1.6)
                hr = _t(d, 10)
                self.au("QUERY_ACCELERATION_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=credits, warehouse_id=1002,
                    warehouse_name="WH_BI"))
                meter(d, "QUERY_ACCELERATION", hr, credits, 1002, "WH_BI", "WAREHOUSE")
            # serverless tasks
            for tid_, tn in ((8501, "T_SERVERLESS_REFRESH"), (8502, "T_SERVERLESS_CLEAN")):
                credits = (0.5 if tid_ == 8501 else 0.05) * rng.uniform(0.5, 1.5)
                hr = _t(d, 2 if tid_ == 8501 else 4)
                self.au("SERVERLESS_TASK_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=round(credits, 6), task_id=tid_,
                    task_name=tn, schema_id=self.schema_id[("ANALYTICS_DB", "MARTS")], schema_name="MARTS",
                    database_id=102, database_name="ANALYTICS_DB"))
                meter(d, "SERVERLESS_TASK", hr, credits, tid_, tn, "TASK", "ANALYTICS_DB", "MARTS")
            # snowpipe (pipe usage is filled in loading())
            # replication
            if d.weekday() == 0:
                credits = 2.5 * rng.uniform(0.7, 1.3)
                hr = _t(d, 6)
                self.au("REPLICATION_GROUP_USAGE_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), replication_group_name="RG_MAIN",
                    replication_group_id=1, credits_used=credits, bytes_transferred=int(credits * 4e10)))
                self.au("DATABASE_REPLICATION_USAGE_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), database_id=102, database_name="ANALYTICS_DB",
                    credits_used=credits / 2, bytes_transferred=int(credits * 2e10)))
                meter(d, "REPLICATION", hr, credits, 9001, "RG_MAIN", "REPLICATION_GROUP")
            # snowpipe streaming file migration
            if rng.random() < 0.3:
                hr = _t(d, 8)
                credits = 0.05
                t = next(t for t in self.tables if t["name"] == "ORDERS_STG")
                self.au("SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=credits,
                    num_bytes_migrated=int(2e9), num_rows_migrated=int(1e7), table_id=t["id"], table_name=t["name"],
                    schema_name=t["schema"], database_name=t["db"]))
                meter(d, "SNOWPIPE_STREAMING", hr, credits, 9201, "stream-client-1", "CLIENT", "RAW_DB", "STAGING")
            # data quality monitoring
            if rng.random() < 0.5:
                t = next(t for t in self.tables if t["name"] == "ORDERS")
                credits = 0.3
                hr = _t(d, 7)
                self.au("DATA_QUALITY_MONITORING_USAGE_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=credits, table_id=t["id"],
                    table_name=t["name"], schema_name=t["schema"], database_name=t["db"]))
                meter(d, "DATA_QUALITY_MONITORING", hr, credits, t["id"], t["name"], "TABLE", t["db"], t["schema"])
            # AI, SPCS and telemetry
            if d >= self.day(120):
                credits = 3.0 * rng.uniform(0.3, 1.8) * (2.5 if d >= self.day(20) else 1)
                meter(d, "AI_SERVICES", _t(d, 13), credits, None, "CORTEX", None)
            if rng.random() < 0.7:
                credits = 1.5 * rng.uniform(0.8, 1.2)
                self.au("SNOWPARK_CONTAINER_SERVICES_HISTORY", dict(
                    start_time=_t(d, 11), end_time=_t(d, 12), compute_pool_name="POOL_ML", compute_pool_id=9101,
                    is_exclusive=True, application_name=None, credits_used=credits))
                meter(d, "SNOWPARK_CONTAINER_SERVICES", _t(d, 11), credits, 9101, "POOL_ML", "COMPUTE_POOL")
            if rng.random() < 0.9:
                credits = 0.2
                self.au("EVENT_USAGE_HISTORY", dict(start_time=_t(d, 0), end_time=_t(d, 1), credits_used=credits,
                                                    bytes_ingested=int(1e9)))
                meter(d, "TELEMETRY_DATA_INGEST", _t(d, 0), credits, None, "EVENTS", None)
            if d >= self.day(90):
                self.au("HYBRID_TABLE_USAGE_HISTORY", dict(object_type="ACCOUNT", start_time=_t(d, 0),
                                                           end_time=_t(d, 1), credits_used=0.4))
                meter(d, "HYBRID_TABLE_REQUESTS", _t(d, 0), 0.4, None, None, None)
        self.svc_daily = svc_daily
        # METERING_DAILY_HISTORY: warehouses plus serverless
        for d in self.hist_days:
            dd = self.daily_wh.get(d, {"compute": 0.0, "cs": 0.0})
            compute, cs = dd["compute"], dd["cs"]
            self.daily_row(d, "WAREHOUSE_METERING", compute, cs)
        for (d, service), dd in svc_daily.items():
            self.daily_row(d, service, dd["compute"], dd["cs"])

    def daily_row(self, d, service, compute, cs) -> None:
        adj = -min(cs, 0.1 * compute) if service == "WAREHOUSE_METERING" else -cs * 0
        self.au("METERING_DAILY_HISTORY", dict(
            service_type=service, usage_date=d, credits_used_compute=compute, credits_used_cloud_services=cs,
            credits_used=compute + cs, credits_adjustment_cloud_services=adj, credits_billed=compute + cs + adj))

    # ---- tasks and alerts -------------------------------------------------------------------------
    def tasks_alerts(self) -> None:
        rng = self.rng
        # name, db, schema, schedule, warehouse, owner, fail_rate, state (SHOW), pred
        tasks = [
            ("T_LOAD_ORDERS", "RAW_DB", "LANDING", "USING CRON 0 1 * * * UTC", "WH_ETL", "ETL_ROLE", 0.0, "started", None),
            ("T_LOAD_CUSTOMERS", "RAW_DB", "LANDING", "USING CRON 30 1 * * * UTC", "WH_ETL", "ETL_ROLE", 0.05, "started", None),
            ("T_BUILD_MARTS", "ANALYTICS_DB", "MARTS", None, "WH_ETL", "DATA_ADMIN", 0.02, "started", "T_LOAD_ORDERS"),
            ("T_FLAKY", "ANALYTICS_DB", "MARTS", "60 MINUTE", "WH_ADHOC", "DEV_ROLE", 0.85, "started", None),
            ("T_SERVERLESS_REFRESH", "ANALYTICS_DB", "MARTS", "USING CRON 0 2 * * * UTC", None, "DATA_ADMIN", 0.01, "started", None),
            ("T_SERVERLESS_CLEAN", "ANALYTICS_DB", "MARTS", "USING CRON 0 4 * * * UTC", None, "DATA_ADMIN", 0.0, "started", None),
            ("T_OLD_SUSPENDED", "SANDBOX_DB", "SCRATCH", "USING CRON 0 5 * * * UTC", "WH_ADHOC", "DEV_ROLE", 0.0, "suspended", None),
            ("T_HOURLY_CHECK", "ANALYTICS_DB", "CORE", "60 MINUTE", "WH_BI", "SYSADMIN", 0.1, "started", None),
        ]
        self.tasks = tasks
        gv = 1
        for i, (name, db, sch, sched, wh, owner, fail, state, pred) in enumerate(tasks):
            tid = 8500 + i if name.startswith("T_SERVERLESS") else 8600 + i
            if name == "T_SERVERLESS_REFRESH":
                tid = 8501
            if name == "T_SERVERLESS_CLEAN":
                tid = 8502
            root_id = str(tid) if pred is None else "8600"
            self.au("TASK_VERSIONS", dict(
                root_task_id=root_id, graph_version=gv, graph_version_created_on=_t(self.day(300), 9), name=name,
                id=str(tid), database_id=self.dbs[db], database_name=db, schema_id=self.schema_id[(db, sch)],
                schema_name=sch, owner=owner, warehouse_name=wh, schedule=sched, predecessors=[pred] if pred else None,
                state="started", allow_overlapping_execution=False, last_committed_on=_t(self.day(300 - i), 9),
                last_suspended_on=_t(self.day(45), 9) if state == "suspended" else None,
                scheduling_mode=None))
            self.au("TASK_VERSIONS", dict(
                root_task_id=root_id, graph_version=gv + 1, graph_version_created_on=_t(self.day(100), 9), name=name,
                id=str(tid), database_id=self.dbs[db], database_name=db, schema_id=self.schema_id[(db, sch)],
                schema_name=sch, owner=owner, warehouse_name=wh, schedule=sched, predecessors=[pred] if pred else None,
                state=state, last_committed_on=_t(self.day(100 - i), 9)))
            if state == "suspended" and name == "T_OLD_SUSPENDED":
                runs_from = 120
            else:
                runs_from = QUERY_DAYS
            runs_to = 60 if state == "suspended" else 0
            per_day = 24 if sched and "MINUTE" in sched else 1
            for d in self.days(runs_from):
                if (self.as_of - d).days <= runs_to:
                    continue
                for k in range(per_day):
                    when = _t(d, k if per_day > 1 else 1, rng.randint(0, 59))
                    r = rng.random()
                    st = "SUCCEEDED"
                    err_code, err_msg = None, None
                    if r < fail:
                        st = "FAILED"
                        err_code, err_msg = rng.choice([("000630", "Statement reached its statement or warehouse timeout"),
                                                        ("002003", "SQL compilation error: object does not exist"),
                                                        ("100132", "JavaScript execution error")])
                    elif rng.random() < 0.02:
                        st = "SKIPPED"
                    elif rng.random() < 0.01:
                        st = "CANCELLED"
                    dur = rng.uniform(40, 400)
                    if name == "T_BUILD_MARTS" and (self.as_of - d).days < 15:
                        dur *= 2.6                                  # a task that has slowed down
                    run_id = int(when.timestamp() * 1000) + i
                    if wh and st in ("SUCCEEDED", "FAILED"):
                        self.synthetic_query(f"01t-{run_id}", wh, when + dt.timedelta(seconds=1), dur, owner,
                                             "CALL" if name == "T_BUILD_MARTS" else "INSERT", db=db,
                                             schema_name=sch)
                    self.au("TASK_HISTORY", dict(
                        name=name, condition_text="SYSTEM$STREAM_HAS_DATA('S')" if name == "T_BUILD_MARTS" and st == "SKIPPED" else None,
                        schema_name=sch, task_schema_id=self.schema_id[(db, sch)], database_name=db,
                        task_database_id=self.dbs[db], scheduled_time=when,
                        completed_time=when + dt.timedelta(seconds=dur) if st != "SKIPPED" else when,
                        query_start_time=when + dt.timedelta(seconds=1) if st != "SKIPPED" else None, state=st,
                        query_id=f"01t-{run_id}" if st != "SKIPPED" else None, error_code=err_code, error_message=err_msg,
                        graph_version=gv + 1, run_id=run_id, root_task_id=root_id, scheduled_from="SCHEDULE" if pred is None else "TASK",
                        attempt_number=1, instance_id=1, graph_run_group_id=f"g{run_id}"))
            if pred is None and state != "suspended":
                for d in self.days(min(runs_from, 100)):
                    when = _t(d, 1, 0)
                    st = "FAILED" if rng.random() < fail else "SUCCEEDED"
                    self.au("COMPLETE_TASK_GRAPHS", dict(
                        root_task_name=name, database_name=db, schema_name=sch, state=st, scheduled_from="SCHEDULE",
                        first_error_task_name=name if st == "FAILED" else None,
                        first_error_code=630 if st == "FAILED" else None,
                        first_error_message="timeout" if st == "FAILED" else None, scheduled_time=when,
                        query_start_time=when, completed_time=when + dt.timedelta(minutes=8), root_task_id=root_id,
                        graph_version=gv + 1, run_id=int(when.timestamp() * 1000), attempt_number=1,
                        graph_run_group_id=f"g{int(when.timestamp())}"))
        # alerts
        for i, (name, fail) in enumerate([("ALERT_LAG", 0.0), ("ALERT_CREDITS", 0.3)]):
            for d in self.days(60):
                for k in range(3):
                    when = _t(d, 6 + k * 6)
                    st = rng.choice(["CONDITION_FALSE"] * 8 + ["TRIGGERED"] + (["CONDITION_FAILED"] if fail else []))
                    self.au("ALERT_HISTORY", dict(
                        name=name, database_name="ANALYTICS_DB", schema_name="CORE", action="CALL notify()",
                        action_query_id=f"01a-{i}{d.toordinal()}{k}" if st == "TRIGGERED" else None,
                        condition="select 1", condition_query_id=f"01c-{i}{d.toordinal()}{k}",
                        error_code=1003 if st == "CONDITION_FAILED" else None,
                        error_message="syntax error" if st == "CONDITION_FAILED" else None, state=st,
                        scheduled_time=when, completed_time=when + dt.timedelta(seconds=30),
                        scheduled_from="SCHEDULE", was_auto_suspended=False))
        for d in self.days(60):
            self.au("SERVERLESS_ALERT_HISTORY", dict(
                start_time=_t(d, 6), end_time=_t(d, 7), alert_id=8801, alert_name="ALERT_LAG", credits_used=0.01,
                schema_name="CORE", database_name="ANALYTICS_DB"))

    # ---- loading -----------------------------------------------------------------------------------------
    def loading(self) -> None:
        rng = self.rng
        pipes = [(8701, "P_ORDERS", "RAW_DB", "LANDING", True, "s3://fake-bucket/landing/orders/", 0.4, 400),
                 (8702, "P_CUSTOMERS", "RAW_DB", "LANDING", True, "s3://fake-bucket/landing/customers/", 0.15, 15),
                 (8703, "P_EVENTS_OLD", "RAW_DB", "LANDING", False, "s3://fake-bucket/landing/events/", 0.0, 0),
                 (8704, "P_SMALLFILES", "RAW_DB", "STAGING", True, "s3://fake-bucket/landing/tiny/", 0.9, 5000)]
        for pid, name, db, sch, auto, loc, base, files in pipes:
            self.au("PIPES", dict(
                pipe_id=pid, pipe_name=name, pipe_schema_id=self.schema_id[(db, sch)], pipe_schema=sch,
                pipe_catalog_id=self.dbs[db], pipe_catalog=db, is_autoingest_enabled="YES" if auto else "NO",
                notification_channel_name="arn:aws:sqs:us-east-1:000000000000:fake" if auto else None,
                pipe_owner="ETL_ROLE", definition="copy into t from @s", created=_t(self.day(300), 9),
                last_altered=_t(self.day(60), 9), owner_role_type="ROLE"))
            for d in self.days(HISTORY_DAYS):
                if base == 0.0 and (self.as_of - d).days < 90:
                    continue
                credits = base * rng.uniform(0.5, 1.5)
                nfiles = int(files * rng.uniform(0.5, 1.5))
                hr = _t(d, 4)
                self.au("PIPE_USAGE_HISTORY", dict(
                    pipe_id=pid, pipe_name=name, start_time=hr, end_time=hr + dt.timedelta(hours=1),
                    credits_used=credits, bytes_inserted=float(nfiles * (60_000 if name == "P_SMALLFILES" else 40_000_000)),
                    files_inserted=nfiles, bytes_billed=int(nfiles * 4e7)))
                svc = self.svc_daily.setdefault((d, "PIPE"), {"compute": 0.0, "cs": 0.0})
                svc["compute"] += credits
                self.au("METERING_HISTORY", dict(
                    service_type="PIPE", start_time=hr, end_time=hr + dt.timedelta(hours=1), entity_id=pid,
                    entity_type="PIPE", name=name, database_name=db, credits_used_compute=credits,
                    credits_used_cloud_services=0, credits_used=credits, files=nfiles))
                # daily aggregate for PIPE is written at the end of loading
        # auto-refresh (PIPE_NAME NULL) rows
        for d in self.days(60):
            self.au("PIPE_USAGE_HISTORY", dict(pipe_id=None, pipe_name=None, start_time=_t(d, 5), end_time=_t(d, 6),
                                               credits_used=0.02, bytes_inserted=0.0, files_inserted=12, bytes_billed=0))
        for d in self.hist_days:
            dd = self.svc_daily.get((d, "PIPE"))
            if dd:
                self.daily_row(d, "PIPE", dd["compute"], 0.0)
        # copy history
        for d in self.days(60):
            for pid, name, db, sch, auto, loc, base, files in pipes:
                if base == 0.0:
                    continue
                nrows = min(int(files / 40) + 2, 60)
                for k in range(nrows):
                    size = 60_000 if name == "P_SMALLFILES" else int(rng.uniform(5e6, 8e7))
                    status = "Loaded"
                    err = None
                    if rng.random() < 0.02:
                        status = rng.choice(["Load failed", "Partially loaded"])
                        err = "Numeric value 'x' is not recognized"
                    self.au("COPY_HISTORY", dict(
                        file_name=f"landing/{name.lower()}/{d.isoformat()}/f{k}.csv.gz", stage_location=loc,
                        last_load_time=_t(d, 4, rng.randint(0, 59)), row_count=int(size / 100), row_parsed=int(size / 100),
                        file_size=size, first_error_message=err, first_error_line_number=12 if err else None,
                        first_error_column_name="AMOUNT" if err else None, error_count=3 if err else 0, error_limit=1,
                        status=status, table_id=self.tables[0]["id"] if "ORDERS" in name else self.tables[1]["id"],
                        table_name="ORDERS_RAW" if "ORDERS" in name else "CUSTOMERS_RAW", table_schema_name="LANDING",
                        table_catalog_name="RAW_DB", pipe_catalog_name=db, pipe_schema_name=sch, pipe_name=name,
                        pipe_received_time=_t(d, 4), first_commit_time=_t(d, 4, 2), bytes_billed=size))
            for k in range(3):                                 # bulk COPY, no pipe
                self.au("COPY_HISTORY", dict(
                    file_name=f"archive/{d.isoformat()}/b{k}.csv", stage_location="s3://fake-bucket/archive/",
                    last_load_time=_t(d, 2), row_count=100000, row_parsed=100000, file_size=int(rng.uniform(1e7, 1e8)),
                    error_count=0, error_limit=1, status="Loaded", table_id=self.tables[3]["id"], table_name="ORDERS_STG",
                    table_schema_name="STAGING", table_catalog_name="RAW_DB"))
        # streaming clients
        for d in self.days(30):
            self.au("SNOWPIPE_STREAMING_CLIENT_HISTORY", dict(
                client_name="stream-client-1", snowflake_provided_id="c1", event_timestamp=_t(d, 8),
                event_type="CLIENT_CREATED", blob_size_bytes=int(rng.uniform(1e6, 1e8))))
        # data transfer
        for d in self.days(HISTORY_DAYS):
            for tt, region, gb in (("COPY", "AWS_EU_WEST_1", 30), ("REPLICATION", "AWS_US_WEST_2", 20),
                                   ("EXTERNAL_FUNCTION", None, 2)):
                if region is None:
                    tcloud, tregion = None, None
                else:
                    tcloud, tregion = "AWS", region
                self.au("DATA_TRANSFER_HISTORY", dict(
                    start_time=_t(d, 3), end_time=_t(d, 4), source_cloud="AWS", source_region=REGION,
                    target_cloud=tcloud, target_region=tregion, bytes_transferred=int(gb * 1e9 * rng.uniform(0.5, 1.5)),
                    transfer_type=tt))

    # ---- dynamic tables ---------------------------------------------------------------------------------------
    def dynamic_tables(self) -> None:
        rng = self.rng
        dts = [("DAILY_SALES", 3600, 0.02), ("CUSTOMER_LTV", 900, 0.12)]
        for name, lag, fail in dts:
            t = next(t for t in self.tables if t["name"] == name)
            for d in self.days(60):
                per_day = 24 if lag >= 3600 else 96
                for k in range(0, per_day, 1):
                    ts_ = _t(d) + dt.timedelta(seconds=k * 86400 // per_day)
                    r = rng.random()
                    state, code, msg = "SUCCEEDED", None, None
                    if r < fail:
                        state, code, msg = "FAILED", "100132", "Refresh failed: upstream error"
                    elif r < fail * 1.4:
                        state = "UPSTREAM_FAILED"
                    action = rng.choice(["INCREMENTAL"] * 6 + ["NO_DATA"] * 3 + ["FULL"] + (["REINITIALIZE"] if rng.random() < 0.05 else []))
                    dur = rng.uniform(3, 120) * (10 if name == "CUSTOMER_LTV" and rng.random() < 0.1 else 1)
                    if state != "UPSTREAM_FAILED" and action != "NO_DATA":
                        self.synthetic_query(f"01d-{name[:3]}{d.toordinal()}{k}", "WH_ETL", ts_, dur, "DATA_ADMIN", "MERGE")
                    self.au("DYNAMIC_TABLE_REFRESH_HISTORY", dict(
                        name=name, schema_name="MARTS", database_name="ANALYTICS_DB", id=t["id"],
                        schema_id=self.schema_id[("ANALYTICS_DB", "MARTS")], database_id=102,
                        qualified_name=f"ANALYTICS_DB.MARTS.{name}", state=state, state_code=code, state_message=msg,
                        query_id=f"01d-{name[:3]}{d.toordinal()}{k}", data_timestamp=ts_ - dt.timedelta(seconds=rng.randint(0, lag)),
                        refresh_start_time=ts_, refresh_end_time=ts_ + dt.timedelta(seconds=dur),
                        completion_target=ts_ + dt.timedelta(seconds=lag), statistics='{"numInsertedRows":10}',
                        refresh_action=action, refresh_trigger="SCHEDULED" if rng.random() > 0.03 else "MANUAL",
                        target_lag_sec=lag))

    # ---- storage --------------------------------------------------------------------------------------------------
    def storage(self) -> None:
        rng = self.rng
        GB = 1024 ** 3
        tot_active = sum((t["bytes"] or 0) for t in self.tables if t["type"] == "BASE TABLE" and not t.get("demo"))
        demo_db_bytes = self.demo_db_bytes() if self.demo else {}
        for i, d in enumerate(self.days(HISTORY_DAYS)):
            growth = 0.75 + 0.25 * (i / HISTORY_DAYS)
            active = tot_active * growth
            demo_db = sum(b for b, _ in demo_db_bytes.values()) * growth
            demo_fs = sum(f for _, f in demo_db_bytes.values()) * growth
            self.au("STORAGE_USAGE", dict(
                usage_date=d, storage_bytes=active * 1.05 + demo_db, stage_bytes=60 * GB * growth,
                failsafe_bytes=active * 0.25 + demo_fs,
                hybrid_table_storage_bytes=0.2 * GB, archive_storage_cool_bytes=0, archive_storage_cold_bytes=0,
                archive_storage_retrieval_temp_bytes=0))
            self.au("STAGE_STORAGE_USAGE_HISTORY", dict(usage_date=d, average_stage_bytes=60 * GB * growth))
            for db, share in (("RAW_DB", 0.62), ("ANALYTICS_DB", 0.33), ("SANDBOX_DB", 0.03), ("DEV_DB", 0.002)):
                self.au("DATABASE_STORAGE_USAGE_HISTORY", dict(
                    usage_date=d, database_id=self.dbs[db], database_name=db,
                    average_database_bytes=active * share * 1.05, average_failsafe_bytes=active * share * 0.25,
                    average_hybrid_table_storage_bytes=0))
            for (dbid, db), (b, fs) in demo_db_bytes.items():
                self.au("DATABASE_STORAGE_USAGE_HISTORY", dict(
                    usage_date=d, database_id=dbid, database_name=db, average_database_bytes=b * growth,
                    average_failsafe_bytes=fs * growth, average_hybrid_table_storage_bytes=0))
            if d < self.day(40):
                self.au("DATABASE_STORAGE_USAGE_HISTORY", dict(
                    usage_date=d, database_id=105, database_name="OLD_DB", deleted=None,
                    average_database_bytes=30 * GB, average_failsafe_bytes=5 * GB))
            elif d < self.day(35):
                pass

    # ---- governance -------------------------------------------------------------------------------------------------
    def governance(self) -> None:
        rng = self.rng
        # tags: system classification tags on sensitive columns, a custom cost centre tag
        cols = [("ANALYTICS_DB", "CORE", "CUSTOMERS", "EMAIL", "EMAIL", "IDENTIFIER"),
                ("ANALYTICS_DB", "CORE", "CUSTOMERS", "PHONE", "PHONE_NUMBER", "IDENTIFIER"),
                ("ANALYTICS_DB", "CORE", "CUSTOMERS", "BIRTH_DATE", "DATE_OF_BIRTH", "QUASI_IDENTIFIER"),
                ("ANALYTICS_DB", "CORE", "CUSTOMERS", "SALARY", "SALARY", "SENSITIVE"),
                ("RAW_DB", "LANDING", "CUSTOMERS_RAW", "EMAIL", "EMAIL", "IDENTIFIER"),
                ("RAW_DB", "LANDING", "CUSTOMERS_RAW", "SSN", "US_SSN", "IDENTIFIER"),
                ("ANALYTICS_DB", "CORE", "ORDERS", "CARD_NUMBER", "PAYMENT_CARD", "IDENTIFIER")]
        tid = {t["name"]: t["id"] for t in self.tables}
        for db, sch, tbl, col, sem, priv in cols:
            for tag, val in (("SEMANTIC_CATEGORY", sem), ("PRIVACY_CATEGORY", priv)):
                self.au("TAG_REFERENCES", dict(
                    tag_database="SNOWFLAKE", tag_schema="CORE", tag_id=None, tag_name=tag, tag_value=val,
                    object_database=db, object_schema=sch, object_id=tid[tbl], object_name=tbl, domain="COLUMN",
                    column_id=zlib.crc32(f"{tbl}.{col}".encode()) % 100000, column_name=col, apply_method="CLASSIFIED"))
        self.au("TAG_REFERENCES", dict(
            tag_database="GOV_DB", tag_schema="TAGS", tag_id=9301, tag_name="PII", tag_value="true",
            object_database="ANALYTICS_DB", object_schema="CORE", object_id=tid["CUSTOMERS"], object_name="CUSTOMERS",
            domain="TABLE", apply_method="MANUAL"))
        # the demo account uses one cost-center scheme: its teams' codes
        ccmap = {"DATA_PLATFORM": "CC-1400", "ANALYTICS": "CC-1600", "DATA_SCIENCE": "CC-1500"} if self.demo else {}
        for wh_name, cc in (("WH_ETL", "DATA_PLATFORM"), ("WH_BI", "ANALYTICS"), ("WH_ML", "DATA_SCIENCE"), ("WH_ADHOC", None)):
            cc = ccmap.get(cc, cc)
            if cc:
                self.au("TAG_REFERENCES", dict(
                    tag_database="GOV_DB", tag_schema="TAGS", tag_id=9302, tag_name="COST_CENTER", tag_value=cc,
                    object_id=self.wh_by_name[wh_name]["id"], object_name=wh_name, domain="WAREHOUSE",
                    apply_method="MANUAL"))
        for db, cc in (("RAW_DB", "DATA_PLATFORM"), ("ANALYTICS_DB", "ANALYTICS")):
            cc = ccmap.get(cc, cc)
            self.au("TAG_REFERENCES", dict(
                tag_database="GOV_DB", tag_schema="TAGS", tag_id=9302, tag_name="COST_CENTER", tag_value=cc,
                object_id=self.dbs[db], object_name=db, domain="DATABASE", apply_method="MANUAL"))
        for r, cc in (("ETL_ROLE", "DATA_PLATFORM"), ("BI_ROLE", "ANALYTICS")):
            cc = ccmap.get(cc, cc)
            self.au("TAG_REFERENCES", dict(
                tag_database="GOV_DB", tag_schema="TAGS", tag_id=9302, tag_name="COST_CENTER", tag_value=cc,
                object_id=6000 + self.roles.index(r), object_name=r, domain="ROLE", apply_method="MANUAL"))
        for u, team in (("ANALYST_CARA", "FINANCE"), ("SVC_ETL", "DATA_PLATFORM"), ("DEV_HUGO", "DATA_SCIENCE")):
            self.au("TAG_REFERENCES", dict(
                tag_database="GOV_DB", tag_schema="TAGS", tag_id=9303, tag_name="TEAM", tag_value=team,
                object_id=5000 + self.users.index(u), object_name=u, domain="USER", apply_method="MANUAL"))
        # masking and row access policies
        for i, (n, body) in enumerate([("MASK_EMAIL", "CASE WHEN CURRENT_ROLE() IN ('ADMIN') THEN VAL ELSE '***' END"),
                                       ("MASK_PII_TAG", "CASE WHEN IS_ROLE_IN_SESSION('ACCOUNTADMIN') THEN VAL ELSE NULL END"),
                                       ("MASK_UNUSED", "CASE WHEN CURRENT_ROLE() = 'X' THEN VAL ELSE NULL END")]):
            self.au("MASKING_POLICIES", dict(
                policy_id=9400 + i, policy_name=n, policy_schema_id=self.schema_id[("ANALYTICS_DB", "PUBLIC")],
                policy_schema="PUBLIC", policy_catalog_id=102, policy_catalog="ANALYTICS_DB", policy_owner="SYSADMIN",
                owner_role_type="ROLE", policy_signature="(VAL VARCHAR)", policy_return_type="VARCHAR",
                policy_body=body, created=_t(self.day(200), 9), last_altered=_t(self.day(50), 9)))
        for i, n in enumerate(["RAP_REGION", "RAP_UNUSED"]):
            self.au("ROW_ACCESS_POLICIES", dict(
                policy_id=9450 + i, policy_name=n, policy_schema="PUBLIC", policy_catalog="ANALYTICS_DB",
                policy_owner="SYSADMIN", owner_role_type="ROLE", policy_signature="(R VARCHAR)",
                policy_return_type="BOOLEAN", policy_body="CURRENT_ROLE() = 'ADMIN'", created=_t(self.day(200), 9),
                last_altered=_t(self.day(50), 9)))
        pol = lambda **k: self.au("POLICY_REFERENCES", dict(policy_status="ACTIVE", **k))
        pol(policy_db="ANALYTICS_DB", policy_schema="PUBLIC", policy_id=9400, policy_name="MASK_EMAIL",
            policy_kind="MASKING_POLICY", ref_database_name="ANALYTICS_DB", ref_schema_name="CORE",
            ref_entity_name="CUSTOMERS", ref_entity_domain="TABLE", ref_column_name="EMAIL")
        pol(policy_db="ANALYTICS_DB", policy_schema="PUBLIC", policy_id=9401, policy_name="MASK_PII_TAG",
            policy_kind="MASKING_POLICY", ref_database_name="GOV_DB", ref_schema_name="TAGS",
            ref_entity_name="PII", ref_entity_domain="TAG", tag_database="GOV_DB", tag_schema="TAGS",
            tag_name="PII")
        pol(policy_db="ANALYTICS_DB", policy_schema="PUBLIC", policy_id=9450, policy_name="RAP_REGION",
            policy_kind="ROW_ACCESS_POLICY", ref_database_name="ANALYTICS_DB", ref_schema_name="CORE",
            ref_entity_name="ORDERS", ref_entity_domain="TABLE", ref_arg_column_names="[REGION]")
        pol(policy_db="SEC_DB", policy_schema="POLICIES", policy_id=9500, policy_name="NP_CORP",
            policy_kind="NETWORK_POLICY", ref_database_name=None, ref_schema_name=None, ref_entity_name=ACCOUNT_NAME,
            ref_entity_domain="ACCOUNT")
        pol(policy_db="SEC_DB", policy_schema="POLICIES", policy_id=9500, policy_name="NP_CORP",
            policy_kind="NETWORK_POLICY", ref_entity_name="SVC_ETL", ref_entity_domain="USER")
        # classification
        for t in ("CUSTOMERS", "CUSTOMERS_RAW", "ORDERS", "EVENTS_RAW", "PRODUCTS"):
            tb = next(x for x in self.tables if x["name"] == t)
            res = {}
            for col, sem in (("EMAIL", "EMAIL"), ("PHONE", "PHONE_NUMBER"), ("NAME", "NAME"), ("ID", None)):
                if sem:
                    res[col] = {"recommendation": {"semantic_category": sem, "privacy_category": "IDENTIFIER",
                                                   "confidence": "HIGH"}, "valid_value_ratio": 1.0}
                else:
                    res[col] = {"recommendation": None, "valid_value_ratio": 1.0}
            self.au("DATA_CLASSIFICATION_LATEST", dict(
                table_id=tb["id"], table_name=t, schema_id=self.schema_id[(tb["db"], tb["schema"])],
                schema_name=tb["schema"], database_id=self.dbs[tb["db"]], database_name=tb["db"], result=res,
                status="CLASSIFIED" if t != "PRODUCTS" else "REVIEWED", trigger_type="MANUAL" if t != "ORDERS" else "AUTO CLASSIFICATION",
                last_classified_on=_t(self.day(30 if t != "EVENTS_RAW" else 200), 9),
                last_classification_attempt=_t(self.day(30), 9)))
        # network / password / session policies, secrets, shares
        self.au("NETWORK_POLICIES", dict(id=9500, name="NP_CORP", owner="SECURITYADMIN", owner_role_type="ROLE",
                                         created=_t(self.day(400), 9), last_altered=_t(self.day(100), 9),
                                         allowed_ip_list="203.0.113.0/24,0.0.0.0/0", blocked_ip_list=""))
        self.au("NETWORK_POLICIES", dict(id=9501, name="NP_UNUSED", owner="SECURITYADMIN", owner_role_type="ROLE",
                                         created=_t(self.day(300), 9), last_altered=_t(self.day(300), 9),
                                         allowed_ip_list="198.51.100.0/24", blocked_ip_list=""))
        self.au("PASSWORD_POLICIES", dict(id=9600, name="PW_STD", schema="POLICIES", database="SEC_DB",
                                          owner="SECURITYADMIN", owner_role_type="ROLE", password_min_length=8,
                                          password_max_age_days=0, password_max_retries=5, password_lockout_time_mins=15,
                                          password_history=0, created=_t(self.day(300), 9), last_altered=_t(self.day(300), 9)))
        self.au("SESSION_POLICIES", dict(id=9700, name="SP_STD", schema="POLICIES", database="SEC_DB",
                                         owner="SECURITYADMIN", owner_role_type="ROLE", session_idle_timeout_mins=240,
                                         session_ui_idle_timeout_mins=240, created=_t(self.day(300), 9),
                                         last_altered=_t(self.day(300), 9)))
        for i, (n, typ, age) in enumerate([("SEC_DB_PW", "PASSWORD", 500), ("SEC_API_KEY", "GENERIC_STRING", 40)]):
            self.au("SECRETS", dict(id=9800 + i, name=n, schema_id=1, schema="SECRETS", database_id=1,
                                    database="SEC_DB", owner="SYSADMIN", owner_role_type="ROLE", secret_type=typ,
                                    created_on=_t(self.day(age), 9), last_altered_on=_t(self.day(age), 9)))
        self.au("SHARES", dict(created_on=_t(self.day(300), 9), modified_on=_t(self.day(100), 9), name="SHARE_PARTNER",
                               owner="ACCOUNTADMIN", database_name="ANALYTICS_DB", secure_objects_only="YES",
                               target_accounts="PARTNER1.ACCT1"))
        for i, (sid, name, sev, n) in enumerate([("CIS1_1", "MFA for all users", "CRITICAL", 2),
                                                 ("CIS1_4", "Network policy on account", "HIGH", 0),
                                                 ("THREAT_1", "Stale users", "MEDIUM", 3),
                                                 ("CIS2_1", "Password policy", "LOW", 1)]):
            self.add("trust_center", "FINDINGS", dict(
                scanner_id=sid, scanner_name=name, scanner_short_description=name, scanner_type="CIS",
                scanner_package_id="CIS_BENCHMARK", scanner_package_name="CIS Benchmarks", severity=sev,
                completion_status="SUCCEEDED", created_on=_t(self.day(2), 3), total_at_risk_count=n,
                at_risk_entities=[{"entity_name": f"U{j}"} for j in range(n)], event_id=f"ev{i}"))
        for d in self.days(40):
            self.add("data_sharing_usage", "LISTING_ACCESS_HISTORY", dict(
                query_token=f"qt-{d.isoformat()}", query_date=d, listing_global_name="GZ1", share_name="SHARE_PARTNER",
                consumer_account_locator="PARTNER1", consumer_account_name="PARTNER_ACCT", is_share=True,
                is_application=False))
        # login history and sessions
        n_login = 0
        clients = [("SNOWFLAKE_UI", "1.0"), ("PYTHON_DRIVER", "3.4.0"), ("JDBC_DRIVER", "3.12.0"),
                   ("ODBC_DRIVER", "3.0.0"), ("PYTHON_DRIVER", "2.9.0"), ("GO_DRIVER", "1.6.0")]
        by_user_ip = {u: f"203.0.113.{10 + i}" for i, u in enumerate(self.users)}
        user_rows: dict[str, dict] = {}
        for r in self.rows[("account_usage", "USERS")]:
            user_rows.setdefault(r["name"], r)
        for (user, d, wh), sid in self.sessions.items():
            n_login += 1
            app_id = env_app = None
            if wh in self.demo_wh_names:
                ctype, app_id, env_app = self.demo_client(user, self.wh_by_name[wh]["like"])
                cver = app_id.split(" ")[-1]
            else:
                ctype, cver = self.choice(clients)
                if user.startswith("SVC_"):
                    ctype, cver = self.choice([("PYTHON_DRIVER", "3.4.0"), ("JDBC_DRIVER", "3.12.0")])
            first = "PASSWORD"
            second = None
            u_row = user_rows[user]
            if u_row["has_rsa_public_key"]:
                first = "RSA_KEYPAIR"
            elif not u_row["has_password"]:
                first = "SAML2_ASSERTION"
            elif u_row["has_mfa"]:
                second = "TOTP" if wh in self.demo_wh_names else "MFA_TOTP"   # base rows keep their old marker (fingerprint)
            ip = by_user_ip[user]
            if user == "ANALYST_CARA" and (self.as_of - d).days < 5:
                ip = "198.51.100.77"               # a new source
            if user == "ADMIN_BOB" and (self.as_of - d).days < 4:
                ip = "198.51.100.99"               # a new source for an admin, password only
            login_at, created_at, closed = _t(d, 8, 0, 0), _t(d, 8), None
            if wh in self.demo_wh_names:                 # signed in just before the session's first statement
                first_q = self.sess_start.get((user, d, wh))
                if first_q is not None:
                    created_at = first_q - dt.timedelta(seconds=1 + sid % 40)
                    login_at = created_at - dt.timedelta(seconds=1)
                closed = self.demo_closed_reason(user, ctype, self.wh_by_name[wh]["like"])
            self.au("LOGIN_HISTORY", dict(
                event_id=sid, event_timestamp=login_at, event_type="LOGIN", user_name=user, client_ip=ip,
                reported_client_type=ctype, reported_client_version=cver, first_authentication_factor=first,
                second_authentication_factor=second, is_success="YES", connection=None,
                login_details=json.dumps({"CLIENT_IP": ip})))
            self.au("SESSIONS", dict(
                session_id=sid, created_on=created_at, user_name=user, authentication_method=first, login_event_id=sid,
                client_application_id=app_id or f"{ctype} {cver}", client_environment=json.dumps(
                    {"APPLICATION": env_app or "app", "OS": "Linux", "OS_VERSION": "5.4"}), is_open="NO",
                closed_reason=closed))
        if self.demo:
            self.demo_last_logins(user_rows, by_user_ip)
        for d in self.days(60):                        # failed sign-ins
            for k in range(self.rng.randint(0, 4)):
                self.au("LOGIN_HISTORY", dict(
                    event_id=9_000_000 + d.toordinal() * 10 + k, event_timestamp=_t(d, 3, k), event_type="LOGIN",
                    user_name=self.choice(["ANALYST_CARA", "ADMIN_BOB", "UNKNOWN_USER", None]),
                    client_ip="192.0.2.%d" % (k + 5), reported_client_type="SNOWFLAKE_UI", reported_client_version="1.0",
                    first_authentication_factor="PASSWORD", is_success="NO", error_code=390100,
                    error_message="Incorrect username or password was specified."))
        # SHOW-ish object views the checks read for compute pools etc. are elsewhere

    # ---- access history --------------------------------------------------------------------------------------------------
    def access_history(self) -> None:
        rng = self.rng
        tid = {t["fqn"]: t for t in self.tables}
        cust_cols = ["ID", "NAME", "EMAIL", "PHONE", "BIRTH_DATE", "SALARY"]

        domain = {"BASE TABLE": "Table", "VIEW": "View", "MATERIALIZED VIEW": "Materialized view",
                  "EXTERNAL TABLE": "Table"}

        def obj(fqn, cols=None):
            if fqn.startswith("SNOWFLAKE_SAMPLE_DATA."):
                return {"objectDomain": "Table", "objectName": fqn, "objectId": 99001,
                        "columns": [{"columnId": 1, "columnName": "ID"}]}
            t = tid[fqn]
            return {"objectDomain": domain[t["type"]], "objectName": fqn, "objectId": t["id"],
                    "columns": [{"columnId": 1000 + i, "columnName": c} for i, c in enumerate(cols or ["ID", "AMOUNT"])]}

        read_sets = {
            "WH_ETL": [["RAW_DB.LANDING.ORDERS_RAW"], ["RAW_DB.LANDING.CUSTOMERS_RAW"], ["ANALYTICS_DB.CORE.ORDERS"],
                       ["ANALYTICS_DB.MARTS.EXT_ORDERS"]],
            "WH_BI": [["ANALYTICS_DB.CORE.ORDERS"], ["ANALYTICS_DB.CORE.ORDERS", "ANALYTICS_DB.CORE.CUSTOMERS"],
                      ["ANALYTICS_DB.MARTS.DAILY_SALES"], ["ANALYTICS_DB.CORE.CUSTOMERS"],
                      ["ANALYTICS_DB.MARTS.SALES_MV"], ["ANALYTICS_DB.MARTS.ICE_EVENTS"],
                      ["ANALYTICS_DB.MARTS.SESSION_STATE"]],
            "WH_ADHOC": [["ANALYTICS_DB.CORE.CUSTOMERS"], ["SANDBOX_DB.SCRATCH.TMP_A"], ["ANALYTICS_DB.CORE.ORDERS"],
                         ["RAW_DB.LANDING.CUSTOMERS_RAW"], ["SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS"]],
            "WH_ADAPTIVE": [["ANALYTICS_DB.CORE.ORDERS"], ["ANALYTICS_DB.MARTS.CUSTOMER_LTV"]],
            "WH_ML": [["ANALYTICS_DB.CORE.ORDERS", "ANALYTICS_DB.CORE.CUSTOMERS"], ["ANALYTICS_DB.CORE.PRODUCTS"]],
            "WH_IDLE": [["DEV_DB.PUBLIC.TEST_TABLE"]],
        }
        demo_q = []
        for r in self.q_rows:
            if r.get("warehouse_name") in self.demo_wh_names:
                demo_q.append(r)                             # its own pass below, from the demo's generator
                continue
            if r["execution_status"] != "SUCCESS" or r["query_type"] in ("SHOW", "DESCRIBE", "USE"):
                continue
            if rng.random() > 0.35:
                continue
            reads = rng.choice(read_sets[r["warehouse_name"]])
            base = []
            for fqn in reads:
                cols = cust_cols if fqn.endswith("CUSTOMERS") or fqn.endswith("CUSTOMERS_RAW") else None
                if cols and rng.random() < 0.5:
                    cols = rng.sample(cols, 3)
                if fqn.endswith("ORDERS") and rng.random() < 0.05:
                    cols = ["ID", "CARD_NUMBER"]
                base.append(obj(fqn, cols))
            direct = list(base)
            if rng.random() < 0.3 and r["warehouse_name"] == "WH_BI":      # via a view
                direct = [{"objectDomain": "View", "objectName": "ANALYTICS_DB.MARTS.V_ORDERS",
                           "objectId": tid["ANALYTICS_DB.MARTS.V_ORDERS"]["id"], "columns": [{"columnId": 1, "columnName": "ID"}]}]
            modified = []
            if r["query_type"] in ("INSERT", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "UPDATE"):
                modified = [{"objectDomain": "Table", "objectName": "ANALYTICS_DB.CORE.ORDERS",
                             "objectId": tid["ANALYTICS_DB.CORE.ORDERS"]["id"],
                             "columns": [{"columnId": 1, "columnName": "ID", "directSources": [], "baseSources": []}]}]
            pols = []
            if any(o["objectName"].endswith("CUSTOMERS") for o in base) and rng.random() < 0.6:
                pols = [{"policyName": "ANALYTICS_DB.PUBLIC.MASK_EMAIL", "policyKind": "Masking policy",
                         "columns": [{"columnName": "EMAIL"}]}]
            self.au("ACCESS_HISTORY", dict(
                query_id=r["query_id"], query_start_time=r["start_time"], user_name=r["user_name"],
                direct_objects_accessed=direct, base_objects_accessed=base, objects_modified=modified,
                policies_referenced=pols, root_query_id=r["query_id"]))
        if self.demo:
            self.demo_access(demo_q, obj)
        # table DML history
        for d in self.days(60):
            for t in self.tables:
                if t["type"] != "BASE TABLE" or t["name"] in ("T_UNUSED_1", "EVENTS_RAW", "OLD_EXPORT") or t.get("demo"):
                    continue
                hr = _t(d, 2)
                self.au("TABLE_DML_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), table_id=t["id"], table_name=t["name"],
                    schema_id=self.schema_id[(t["db"], t["schema"])], schema_name=t["schema"],
                    database_id=self.dbs[t["db"]], database_name=t["db"], rows_added=rng.randint(1000, 1_000_000),
                    rows_removed=rng.randint(0, 5000), rows_updated=rng.randint(0, 100000)))

    # ---- warehouse load and events -------------------------------------------------------------------------------------------
    def warehouse_load_events(self) -> None:
        rng = self.rng
        busy = {"WH_ETL": (range(1, 6), 3.0), "WH_BI": (range(8, 18), 2.0), "WH_ADHOC": (range(9, 19), 0.6),
                "WH_IDLE": (range(0, 0), 0.0), "WH_ADAPTIVE": (range(8, 20), 1.0), "WH_ML": (range(10, 16), 1.2)}
        rows = self.rows.setdefault(("account_usage", "WAREHOUSE_LOAD_HISTORY"), [])
        blocked: dict[tuple, float] = {}                     # (demo warehouse, 5-minute start) -> blocked load
        if self.demo:
            for r in self.q_rows:
                if r.get("warehouse_name") in self.demo_wh_names and r.get("transaction_blocked_time"):
                    st = r["start_time"]
                    key = (r["warehouse_name"], st.replace(minute=st.minute - st.minute % 5, second=0, microsecond=0))
                    blocked[key] = blocked.get(key, 0.0) + min(r["transaction_blocked_time"], 300_000) / 300_000
        for d in self.days(LOAD_DAYS):
            wk = self.is_weekday(d)
            for w in self.wh:
                like = w.get("like", w["name"])
                demo = "like" in w
                if demo and not self.wh_alive(w, d):
                    continue
                rng = self.drng if demo else self.rng        # demo draws never move the base account
                hours, peak = busy[like]
                if demo:
                    hours = range(0) if w["activity"] == 0 else hours
                    peak = max(0.25, peak * w["activity"] * (0.3 if w["oversized"] else 1))
                load_q = 0.2 if w["name"] == "WH_BI" else min(0.7, w.get("queue", 0) * 1.6)
                resumes = set(self.demo_resume_hours(w, like)) if demo else set()
                for h in range(24):
                    for m in range(0, 60, 5):
                        on = h in hours and (wk or like in ("WH_ETL", "WH_ADHOC", "WH_ADAPTIVE", "WH_ML"))
                        if demo and not on:
                            continue                         # the demo keeps only intervals with load
                        running = rng.uniform(0.2, peak) if on else 0.0
                        queued = rng.uniform(0.5, 3.0) if (on and load_q and rng.random() < load_q) else 0.0
                        start = _t(d, h, m)
                        prov = blk = 0.0
                        if demo:                             # cold clusters after a resume; DML waiting on locks
                            first = m == 0 and (h == hours.start or h - 1 not in hours)
                            if (h in resumes and m < 10) or first:
                                prov = rng.uniform(0.05, 0.8)
                            elif rng.random() < 0.01:
                                prov = rng.uniform(0.02, 0.3)
                            blk = round(blocked.get((w["name"], start), 0.0), 3)
                        rows.append(dict(start_time=start, end_time=start + dt.timedelta(minutes=5),
                                         warehouse_id=w["id"], warehouse_name=w["name"], avg_running=running,
                                         avg_queued_load=queued, avg_queued_provisioning=prov,
                                         avg_blocked=blk))
        ev = ["RESUME_WAREHOUSE", "SUSPEND_WAREHOUSE", "SPINUP_CLUSTER", "SPINDOWN_CLUSTER"]
        for d in self.days(60):
            for w in self.wh:
                like = w.get("like", w["name"])
                if not self.wh_alive(w, d):
                    continue
                if "like" in w:
                    self.demo_wh_events(w, d, like)
                    continue
                if like == "WH_IDLE":
                    for h in range(0, 24, 2):
                        self._events(w, d, h, "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", 1)
                        self._events(w, d, h, "SUSPEND_WAREHOUSE", "WAREHOUSE_AUTOSUSPEND", 1, minute=2)
                    continue
                cycles = {"WH_ETL": 6, "WH_BI": 14, "WH_ADHOC": 3, "WH_ADAPTIVE": 5, "WH_ML": 3}[like]
                for k in range(cycles):
                    h = 1 + k * (20 // cycles)
                    self._events(w, d, h, "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", 1)
                    if w["max"] > 1:
                        self._events(w, d, h, "SPINUP_CLUSTER", "MULTI_CLUSTER_SCALE_OUT", 2, minute=5)
                        self._events(w, d, h, "SPINDOWN_CLUSTER", "MULTI_CLUSTER_SCALE_IN", 2, minute=20)
                    self._events(w, d, h, "SUSPEND_WAREHOUSE", "WAREHOUSE_AUTOSUSPEND", 1, minute=30)

    def demo_resume_hours(self, w, like: str) -> list[int]:
        """Hours a demo warehouse auto-resumes, the same for its events and its load history."""
        if like == "WH_IDLE":
            return list(range(0, 24, 2))
        cycles = {"WH_ETL": 6, "WH_BI": 14, "WH_ADHOC": 3, "WH_ADAPTIVE": 5, "WH_ML": 3}[like]
        cycles = 0 if w["activity"] == 0 else max(1, round(cycles * min(w["activity"], 1.5)))
        return [1 + k * (20 // cycles) for k in range(cycles)]

    def demo_wh_events(self, w, d, like: str) -> None:
        """A demo warehouse's resume, suspend and multi-cluster events for one day, with documented reasons."""
        rng = self.drng
        for h in self.demo_resume_hours(w, like):
            if like == "WH_IDLE":
                self._events(w, d, h, "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", None)
                self._events(w, d, h, "SUSPEND_WAREHOUSE", "WAREHOUSE_AUTOSUSPEND", None, minute=2)
                continue
            self._events(w, d, h, "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", None)
            if w["max"] > 1 and (self.is_weekday(d) or rng.random() < 0.3) and rng.random() < 0.6:
                c = rng.randint(2, w["max"])                 # load grew: another cluster started, then stopped
                up, down = rng.randint(3, 12), rng.randint(15, 28)
                self._events(w, d, h, "SPINUP_CLUSTER", "MULTICLUSTER_SPINUP", c, minute=up)
                self._events(w, d, h, "RESUME_CLUSTER", "MULTICLUSTER_SPINUP", c, minute=up + 1)
                self._events(w, d, h, "SPINDOWN_CLUSTER", "MULTICLUSTER_SPINDOWN", c, minute=down)
                self._events(w, d, h, "SUSPEND_CLUSTER", "MULTICLUSTER_SPINDOWN", c, minute=down + 1)
            self._events(w, d, h, "SUSPEND_WAREHOUSE", "WAREHOUSE_AUTOSUSPEND", None, minute=30)
        if w["name"] == "WH_RISK_ETL" and d == self.day(44):  # a Snowpark-optimized trial, converted back
            admin = next((u["name"] for u in self.demo_cat["users"] if u["team"] == w["team"]
                          and u["type"] == "PERSON" and not u["disabled"]), "SYSTEM")
            for state, sec in (("STARTED", 0), ("COMPLETED", 40)):
                self.au("WAREHOUSE_EVENTS_HISTORY", dict(
                    timestamp=_t(d, 15, 10, sec), warehouse_id=w["id"], warehouse_name=w["name"], cluster_number=None,
                    event_name="CONVERT_WAREHOUSE_TYPE", event_reason="CONVERT_TO_STANDARD", event_state=state,
                    user_name=admin, role_name=f"{w['team']}_ADMIN", size=None, cluster_count=None,
                    warehouse_type=None))

    def _events(self, w, d, h, name, reason, cluster, minute=0):
        for state in ("STARTED", "COMPLETED"):
            self.au("WAREHOUSE_EVENTS_HISTORY", dict(
                timestamp=_t(d, h, minute, 0 if state == "STARTED" else 3), warehouse_id=w["id"], warehouse_name=w["name"],
                cluster_number=cluster, event_name=name, event_reason=reason, event_state=state,
                user_name="SYSTEM", role_name=None,
                # only WAREHOUSE_CONSISTENT carries size, cluster count and type; the base rows keep theirs
                size=None if "like" in w else w["size"], cluster_count=None if "like" in w else str(w["max"]),
                warehouse_type=None if "like" in w else w["type"]))

    # ---- AI, blocking, misc ---------------------------------------------------------------------------------------------------------
    def ai_and_other(self) -> None:
        rng = self.rng
        for d in self.days(120):
            self.au("CORTEX_ANALYST_USAGE_HISTORY", dict(
                start_time=_t(d, 14), end_time=_t(d, 15), request_count=rng.randint(5, 80),
                credits=rng.uniform(0.05, 1.2), username=rng.choice(["ANALYST_DAN", "ANALYST_CARA"])))
            for fn, model in (("COMPLETE", "llama3.1-70b"), ("SUMMARIZE", "snowflake-arctic"), ("EMBED_TEXT_768", "e5-base-v2")):
                self.au("CORTEX_FUNCTIONS_USAGE_HISTORY", dict(
                    start_time=_t(d, 15), end_time=_t(d, 16), function_name=fn, model_name=model, warehouse_id=1006,
                    tokens=rng.randint(10_000, 4_000_000), token_credits=rng.uniform(0.05, 2.0)))
            self.au("CORTEX_SEARCH_DAILY_USAGE_HISTORY", dict(
                usage_date=_t(d), database_name="ANALYTICS_DB", schema_name="MARTS", service_name="SEARCH_DOCS",
                service_id=9901, consumption_type="SERVING", credits=rng.uniform(0.2, 0.5)))
        # lock waits
        for d in self.days(40):
            if rng.random() < 0.5:
                start = _t(d, 10, rng.randint(0, 59))
                self.au("LOCK_WAIT_HISTORY", dict(
                    object_id=self.tables[6]["id"], object_name="ORDERS", lock_type="TABLE",
                    schema_id=self.schema_id[("ANALYTICS_DB", "CORE")], schema_name="CORE", database_id=102,
                    database_name="ANALYTICS_DB", query_id=f"01b-{rng.randint(1, self.qn):08d}",
                    transaction_id=rng.randint(1, 10**6), requested_at=start,
                    acquired_at=start + dt.timedelta(seconds=rng.randint(5, 900)),
                    blocker_queries=[{"query_id": f"01b-{rng.randint(1, self.qn):08d}", "transaction_id": 1}]))
        # replication refreshes
        for d in self.days(60):
            if d.weekday() == 0:
                for phase in ("PRIMARY_UPLOADING_METADATA", "PRIMARY_UPLOADING_DATA", "COMPLETED"):
                    self.au("REPLICATION_GROUP_REFRESH_HISTORY", dict(
                        replication_group_name="RG_MAIN", replication_group_id=7101, phase_name=phase,
                        start_time=_t(d, 6), end_time=_t(d, 6, 20), job_uuid=f"job-{d.isoformat()}",
                        total_bytes={"totalBytesToReplicate": {"estimate": int(1e10)}},
                        object_count={"tableCount": 4},
                        primary_snapshot_timestamp=_t(d, 5, 50)))

    # ---- organization ----------------------------------------------------------------------------------------------------------------------------
    def organization(self) -> None:
        rng = self.rng
        accts = [("FAKE01", ACCOUNT_NAME, "ENTERPRISE", "AWS_US_EAST_1", 1.0, 200),
                 ("FAKE02", "FAKE_DEV", "STANDARD", "AWS_US_EAST_1", 0.15, 200),
                 ("FAKE03", "FAKE_DORMANT", "BUSINESS_CRITICAL", "AZURE_WESTEUROPE", 0.02, 100)]
        common = dict(organization_name=ORG_NAME)
        for loc, name, edition, region, scale, active_days in accts:
            self.ou("ACCOUNTS", dict(
                **common, account_name=name, account_locator=loc, account_url=f"https://{name.lower()}.example.com",
                edition=edition, region=region, region_group=None, is_org_admin=(loc == "FAKE01"), is_locked=False,
                is_managed=False, managed_accounts=1 if loc == "FAKE01" else 0, contract_number=4001,
                created_on=_t(self.day(800), 9), altered_on=_t(self.day(30), 9), is_events_account=False,
                comment=None))
        self.ou("ACCOUNTS", dict(**common, account_name="FAKE_OLD", account_locator="FAKE04", edition="STANDARD",
                                 region="AWS_US_EAST_1", contract_number=4001, created_on=_t(self.day(900), 9),
                                 deleted_on=_t(self.day(200), 9)))
        for d in self.days(HISTORY_DAYS):
            own = self.daily_wh.get(d, {"compute": 0.0, "cs": 0.0})
            for loc, name, edition, region, scale, active_days in accts:
                if (self.as_of - d).days > active_days and loc == "FAKE03":
                    pass
                if loc == "FAKE03" and (self.as_of - d).days < 100:
                    continue
                if loc == "FAKE01":
                    rows = [(s, dd["compute"], dd["cs"]) for (dday, s), dd in self.svc_daily.items() if dday == d]
                    rows.append(("WAREHOUSE_METERING", own["compute"], own["cs"]))
                else:
                    rows = [("WAREHOUSE_METERING", 60 * scale * rng.uniform(0.5, 1.5), 3 * scale * rng.uniform(0.5, 1.5))]
                    if loc == "FAKE02":
                        rows.append(("AUTO_CLUSTERING", 2 * rng.uniform(0.5, 1.5), 0.0))
                if loc == "FAKE02" and (self.as_of - d).days in (12, 13):
                    rows = [(sv, c * 6, x * 6) for sv, c, x in rows]           # a spike well above its baseline
                for service, compute, cs in rows:
                    adj = -min(cs, 0.1 * compute) if service == "WAREHOUSE_METERING" else 0.0
                    self.ou("METERING_DAILY_HISTORY", dict(
                        **common, account_name=name, account_locator=loc, region=region, service_type=service,
                        usage_date=d, credits_used_compute=compute, credits_used_cloud_services=cs,
                        credits_used=compute + cs, credits_adjustment_cloud_services=adj,
                        credits_billed=compute + cs + adj))
                    self.ou("USAGE_IN_CURRENCY_DAILY", dict(
                        **common, contract_number=4001, account_name=name, account_locator=loc, region=region,
                        service_level=edition, usage_date=d, usage_type="compute" if service == "WAREHOUSE_METERING" else "compute",
                        usage=compute + cs + adj, currency="USD", usage_in_currency=(compute + cs + adj) * CREDIT_PRICE,
                        balance_source="capacity", billing_type="consumption", rating_type="compute",
                        service_type=service, is_adjustment=False))
                if loc != "FAKE03":
                    tb = 1.4 * scale
                    self.ou("STORAGE_DAILY_HISTORY", dict(
                        **common, service_type="STORAGE", account_name=name, account_locator=loc, region=region,
                        usage_date=d, average_bytes=tb * 1024 ** 4, credits=None))
                    self.ou("USAGE_IN_CURRENCY_DAILY", dict(
                        **common, contract_number=4001, account_name=name, account_locator=loc, region=region,
                        service_level=edition, usage_date=d, usage_type="storage", usage=tb, currency="USD",
                        usage_in_currency=tb * STORAGE_PRICE_TB_DAY, balance_source="capacity",
                        billing_type="consumption", rating_type="storage", service_type="STORAGE", is_adjustment=False))
                    self.ou("USAGE_IN_CURRENCY_DAILY", dict(
                        **common, contract_number=4001, account_name=name, account_locator=loc, region=region,
                        service_level=edition, usage_date=d, usage_type="data transfer", usage=0.05 * scale,
                        currency="USD", usage_in_currency=0.05 * scale * 90, balance_source="capacity",
                        billing_type="consumption", rating_type="data_transfer", service_type="DATA_TRANSFER",
                        is_adjustment=False))
                    self.ou("DATA_TRANSFER_HISTORY", dict(
                        **common, account_name=name, account_locator=loc, region=region, usage_date=d,
                        source_cloud="AWS", source_region=region, target_cloud="AWS", target_region="AWS_EU_WEST_1",
                        bytes_transferred=int(5e10 * scale * rng.uniform(0.5, 1.5)), transfer_type="COPY"))
                    self.ou("RATE_SHEET_DAILY", dict(
                        date=d, **common, contract_number=4001, account_name=name, account_locator=loc, region=region,
                        service_level=edition, usage_type="compute", currency="USD",
                        effective_rate=CREDIT_PRICE if loc == "FAKE01" else 3.9, service_type="COMPUTE",
                        rating_type="compute", billing_type="consumption", is_adjustment=False))
                    self.ou("RATE_SHEET_DAILY", dict(
                        date=d, **common, contract_number=4001, account_name=name, account_locator=loc, region=region,
                        service_level=edition, usage_type="storage", currency="USD", effective_rate=STORAGE_PRICE_TB_DAY,
                        service_type="STORAGE", rating_type="storage", billing_type="consumption", is_adjustment=False))
                    if d.weekday() == 0:
                        self.ou("USAGE_IN_CURRENCY_DAILY", dict(
                            **common, contract_number=4001, account_name=name, account_locator=loc, region=region,
                            service_level=edition, usage_date=d, usage_type="replication", usage=2 * scale,
                            currency="USD", usage_in_currency=2 * scale * CREDIT_PRICE, balance_source="capacity",
                            billing_type="consumption", rating_type="compute", service_type="REPLICATION",
                            is_adjustment=False))
                        self.ou("REPLICATION_USAGE_HISTORY", dict(
                            **common, account_name=name, account_locator=loc, region=region, usage_date=d,
                            database_id=102, database_name="ANALYTICS_DB",
                            credits_used=2 * scale, bytes_transferred=int(3e10 * scale)))
                    self.ou("WAREHOUSE_METERING_HISTORY", dict(
                        **common, account_name=name, account_locator=loc, region=region, service_type="WAREHOUSE_METERING",
                        start_time=_t(d, 1), end_time=_t(d, 2), warehouse_id=1001, warehouse_name="WH_ETL" if loc == "FAKE01" else "WH_DEV",
                        credits_used_compute=10 * scale, credits_used_cloud_services=0.2 * scale,
                        credits_used=10.2 * scale))
                    self.ou("LOGIN_HISTORY", dict(
                        **common, account_name=name, account_locator=loc, event_id=d.toordinal() * 10 + int(scale * 5),
                        event_timestamp=_t(d, 8), event_type="LOGIN", user_name="ADMIN_ALICE" if loc == "FAKE01" else "DEV_GINA",
                        client_ip="203.0.113.5", reported_client_type="SNOWFLAKE_UI",
                        first_authentication_factor="PASSWORD", second_authentication_factor=None if loc == "FAKE02" else "MFA_TOTP",
                        is_success="YES"))
        # contract and balance
        self.ou("CONTRACT_ITEMS", dict(
            **common, contract_number=4001, start_date=self.day(300), end_date=self.day(-65), expiration_date=self.day(-65),
            contract_item="Capacity", currency="USD", amount=250000.0, contract_modified_date=self.day(300)))
        for d in self.days(HISTORY_DAYS):
            i = (self.as_of - d).days
            self.ou("REMAINING_BALANCE_DAILY", dict(
                **common, contract_number=4001, date=d, currency="USD", free_usage_balance=0.0,
                capacity_balance=250000.0 - (300 - i) * 400.0, on_demand_consumption_balance=0.0, rollover_balance=0.0))
        # reader accounts
        for d in self.days(60):
            self.add("reader_account_usage", "WAREHOUSE_METERING_HISTORY", dict(
                reader_account_name="READER_PARTNER", start_time=_t(d, 9), end_time=_t(d, 10), warehouse_id=1,
                warehouse_name="READER_WH", credits_used=1.5, credits_used_compute=1.4, credits_used_cloud_services=0.1))
            self.add("reader_account_usage", "LOGIN_HISTORY", dict(
                reader_account_name="READER_PARTNER", event_timestamp=_t(d, 9), event_type="LOGIN", user_name="R_USER",
                is_success="YES"))
        self.add("reader_account_usage", "RESOURCE_MONITORS", dict(
            reader_account_name="READER_PARTNER", name="RM_READER", created=_t(self.day(200), 9), credit_quota=100,
            used_credits=40, remaining_credits=60.0, owner="ACCOUNTADMIN", level="ACCOUNT", notify=75, suspend=100))

    def task_definition(self, name: str) -> str:
        return {"T_LOAD_CUSTOMERS": "INSERT INTO RAW_DB.LANDING.CUSTOMERS_RAW SELECT * FROM STAGING.S_CUSTOMERS",
                "T_LOAD_ORDERS": "INSERT INTO RAW_DB.LANDING.ORDERS_RAW SELECT * FROM STAGING.S_ORDERS"}.get(name, "select 1")

    def task_condition(self, name: str):
        return {"T_LOAD_CUSTOMERS": "SYSTEM$STREAM_HAS_DATA('RAW_DB.STAGING.S_CUSTOMERS')"}.get(name)

    # ---- SHOW outputs ------------------------------------------------------------------------------------------------------------------------------------------------
    def show_outputs(self) -> None:
        if self.demo:
            self.demo_show()
        for w in self.wh:
            if "like" in w:
                continue                                     # demo warehouses: demo_show
            self.show("warehouses", _wh_show(dict(
                name=w["name"], state="STARTED" if w["name"] in ("WH_ADHOC", "WH_IDLE") else "SUSPENDED", type=w["type"],
                size=w["size"], min_cluster_count=w["min"], max_cluster_count=w["max"], started_clusters=1 if w["name"] == "WH_ADHOC" else 0,
                running=0, queued=0, is_default="N", is_current="N",
                auto_suspend=w["suspend"] if w["suspend"] else None, auto_resume="true", available="", provisioning="",
                quiescing="", other="", created_on=_t(self.day(600), 9), resumed_on=_t(self.day(1), 9),
                updated_on=_t(self.day(20), 9), owner=w["owner"], comment="", enable_query_acceleration="true" if w["name"] == "WH_BI" else "false",
                query_acceleration_max_scale_factor=8 if w["name"] == "WH_BI" else 0,
                resource_monitor=w["monitor"] or "null", scaling_policy="STANDARD", owner_role_type="ROLE",
                resource_constraint=None, generation="2" if w["type"] == "SNOWPARK-OPTIMIZED" else "1")))
        for name, quota, used, freq, notify, susp in (("RM_ETL", 3000.0, 1900.0, "MONTHLY", "80,90", 100),
                                                      ("RM_BI", 800.0, 210.0, "MONTHLY", "75", 100)):
            self.show("resource_monitors", dict(
                name=name, credit_quota=quota, used_credits=used, remaining_credits=quota - used, level="WAREHOUSE",
                frequency=freq, start_time=_t(self.day(60), 0), end_time=None, notify_at=notify, suspend_at=susp,
                suspend_immediately_at=None, created_on=_t(self.day(300), 9), owner="ACCOUNTADMIN", comment="",
                notify_users="ADMIN_ALICE"))
        self.show("resource_monitors", dict(
            name="RM_ACCOUNT", credit_quota=20000.0, used_credits=6000.0, remaining_credits=14000.0, level="ACCOUNT",
            frequency="MONTHLY", start_time=_t(self.day(60), 0), notify_at="90", suspend_at=None,
            suspend_immediately_at=None, created_on=_t(self.day(300), 9), owner="ACCOUNTADMIN"))
        for t in self.tasks:
            name, db, sch, sched, wh, owner, fail, state, pred = t
            self.show("tasks", dict(
                created_on=_t(self.day(300), 9), name=name, id=str(8600 + self.tasks.index(t)), database_name=db,
                schema_name=sch, owner=owner, comment="", warehouse=wh, schedule=sched, predecessors=f'["{db}.{sch}.{pred}"]' if pred else "[]",
                state=state, definition=self.task_definition(name), condition=self.task_condition(name),
                allow_overlapping_execution="false",
                error_integration=None, last_committed_on=_t(self.day(100), 9),
                last_suspended_on=_t(self.day(45), 9) if state == "suspended" else None, owner_role_type="ROLE"))
        streams = [("S_ORDERS", "RAW_DB", "STAGING", "ORDERS_STG", "Table", "false", None, "DEFAULT"),
                   ("S_CUSTOMERS", "RAW_DB", "STAGING", "CUSTOMERS_STG", "Table", "false", None, "APPEND_ONLY"),
                   ("S_STALE", "SANDBOX_DB", "SCRATCH", "OLD_EXPORT", "Table", "true", self.day(30), "DEFAULT"),
                   ("S_ORPHAN", "ANALYTICS_DB", "CORE", "ORDERS", "Table", "false", None, "DEFAULT")]
        for name, db, sch, table, src, stale, stale_after, mode in streams:
            self.show("streams", dict(
                created_on=_t(self.day(200), 9), name=name, database_name=db, schema_name=sch, owner="ETL_ROLE",
                comment="", table_name=f"{db}.{sch}.{table}", source_type=src, base_tables=f"{db}.{sch}.{table}",
                type="DELTA", stale=stale, stale_after=_t(stale_after or self.day(-10), 9), mode=mode,
                invalid_reason=None))
        self.show("external_tables", dict(
            created_on=_t(self.day(150), 9), name="EXT_ORDERS", database_name="ANALYTICS_DB", schema_name="MARTS",
            invalid="false", owner="DATA_ADMIN", stage="S3_LANDING", location="@S3_LANDING/ext", file_format_name="FF_CSV",
            file_format_type="CSV", cloud="aws", region="us-east-1", notification_channel=None,
            last_refreshed_on=_t(self.day(10), 9), table_format="DELTA"))
        self.show("iceberg_tables", dict(
            created_on=_t(self.day(150), 9), name="ICE_EVENTS", database_name="ANALYTICS_DB", schema_name="MARTS",
            owner="DATA_ADMIN", external_volume_name="EXT_VOL", catalog_name="SNOWFLAKE", iceberg_table_type="MANAGED",
            catalog_table_name="ICE_EVENTS", catalog_namespace=None, base_location="ice/events/", can_write_metadata="Y",
            owner_role_type="ROLE"))
        for kind, name, db, to, owner in (("OUTBOUND", "SHARE_PARTNER", "ANALYTICS_DB", "PARTNER1", "ACCOUNTADMIN"),
                                          ("INBOUND", "SAMPLE_DATA", "SNOWFLAKE_SAMPLE_DATA", None, None)):
            self.show("shares", dict(created_on=_t(self.day(300), 9), kind=kind, owner_account="FAKE01", name=name,
                                     database_name=db, to=to, owner=owner, comment="",
                                     listing_global_name="GZ1" if kind == "OUTBOUND" else None))
        params = [("NETWORK_POLICY", "NP_CORP", "", "ACCOUNT"), ("REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_CREATION", "false", "false", ""),
                  ("PREVENT_UNLOAD_TO_INLINE_URL", "false", "false", ""), ("STATEMENT_TIMEOUT_IN_SECONDS", "172800", "172800", ""),
                  ("DATA_RETENTION_TIME_IN_DAYS", "1", "1", ""), ("MIN_DATA_RETENTION_TIME_IN_DAYS", "0", "0", ""),
                  ("CORTEX_ENABLED_CROSS_REGION", "DISABLED", "DISABLED", ""), ("PERIODIC_DATA_REKEYING", "false", "false", ""),
                  ("ENABLE_UNREDACTED_QUERY_SYNTAX_ERROR", "false", "false", ""), ("REQUIRE_STORAGE_INTEGRATION_FOR_STAGE_OPERATION", "false", "false", ""),
                  ("TIMEZONE", "America/Los_Angeles", "America/Los_Angeles", ""), ("SSO_LOGIN_PAGE", "false", "false", ""),
                  ("ENABLE_INTERNAL_STAGES_PRIVATELINK", "false", "false", ""), ("PREVENT_UNLOAD_TO_INTERNAL_STAGES", "false", "false", ""),
                  ("EVENT_TABLE", "", "", ""), ("USE_CACHED_RESULT", "true", "true", "")]
        for key, value, default, level in params:
            self.show("parameters", dict(key=key, value=value, default=default, level=level, description="", type="STRING"))
        for kind, name, typ in (("SECURITY", "SSO_OKTA", "SAML2"), ("SECURITY", "OAUTH_TABLEAU", "OAUTH - TABLEAU_DESKTOP"),
                                ("SECURITY", "OAUTH_CUSTOM", "OAUTH - CUSTOM"), ("SECURITY", "SCIM_OKTA", "SCIM - OKTA"),
                                ("STORAGE", "S3_INT", "EXTERNAL_STAGE"), ("API", "API_INT", "API"),
                                ("EXTERNAL_ACCESS", "EXT_INT", "EXTERNAL_ACCESS")):
            row = dict(name=name, type=typ, category=kind, enabled="true", comment="", created_on=_t(self.day(300), 9))
            self.show("integrations", row)
            if kind == "SECURITY":
                self.show("security_integrations", row)
        for name, origin, kind_, owner in (("SNOWFLAKE_SAMPLE_DATA", "SFC_SAMPLES.SAMPLE_DATA", "IMPORTED DATABASE", None),
                                           ("PARTNER_DATA", "PARTNER1.ACCT1.SHARE_X", "IMPORTED DATABASE", "ACCOUNTADMIN"),
                                           ("RAW_DB", "", "STANDARD", "SYSADMIN"), ("ANALYTICS_DB", "", "STANDARD", "SYSADMIN")):
            self.show("databases", dict(created_on=_t(self.day(500), 9), name=name, is_default="N", is_current="N",
                                        origin=origin, owner=owner, comment="", options="", retention_time="1",
                                        kind=kind_, owner_role_type="ROLE"))
        self.show("managed_accounts", dict(account_name="READER_PARTNER", cloud="aws", region="us-east-1", account_locator="RDR01",
                                           created_on=_t(self.day(200), 9), account_url="https://rdr01.example.com",
                                           is_reader="true", comment=""))
        self.show("replication_groups", dict(
            snowflake_region=REGION, created_on=_t(self.day(300), 9), account_name=ACCOUNT_NAME, name="RG_MAIN",
            type="FAILOVER", comment="", is_primary="true", primary=f"{ORG_NAME}.{ACCOUNT_NAME}",
            object_types="DATABASES", allowed_accounts=f"{ORG_NAME}.FAKE_DEV", organization_name=ORG_NAME,
            account_locator=ACCOUNT_LOCATOR, replication_schedule="USING CRON 0 6 * * 1 UTC", secondary_state=None,
            next_scheduled_refresh=_t(self.day(-2), 6), owner="ACCOUNTADMIN"))
        for name, url, cred, typ, integ in (("S3_LANDING", "s3://fake-bucket/landing/", "Y", "EXTERNAL", "S3_INT"),
                                            ("S3_ARCHIVE", "s3://fake-bucket/archive/", "Y", "EXTERNAL", None),
                                            ("INT_LOAD", "", "N", "INTERNAL", None)):
            self.show("stages", dict(
                created_on=_t(self.day(300), 9), name=name, database_name="RAW_DB", schema_name="LANDING", url=url,
                has_credentials=cred, has_encryption_key="N", owner="ETL_ROLE", comment="", region="us-east-1" if url else None,
                type=typ, cloud="AWS" if url else None, storage_integration=integ, owner_role_type="ROLE"))
        for name in ("APP_DASH", "APP_OLD"):
            self.show("streamlits", dict(created_on=_t(self.day(100), 9), name=name, database_name="ANALYTICS_DB",
                                         schema_name="MARTS", title=name, owner="DATA_ADMIN", comment="",
                                         query_warehouse="WH_ADHOC", owner_role_type="ROLE"))
        self.show("notebooks", dict(created_on=_t(self.day(100), 9), name="NB_EXPLORE", database_name="ANALYTICS_DB",
                                    schema_name="MARTS", owner="DEV_ROLE", comment="", query_warehouse="WH_ML",
                                    code_warehouse="WH_ML"))
        self.show("budget_instances", dict(created_on=_t(self.day(100), 9), name="BUDGET_MAIN", database_name="ANALYTICS_DB",
                                           schema_name="MARTS", current_version="V1", comment="", owner="ACCOUNTADMIN",
                                           owner_role_type="ROLE"))

    # ---- demo account (World(demo=True) only) ----------------------------------------------------------------------
    # The catalog in demo_entities.py flows through the base builders above. Every draw for it comes from
    # self.drng, so the base account's rows are the same with or without the demo.
    def demo_warehouses(self) -> None:
        from tests.fake_snowflake import demo_entities
        self.drng = random.Random(f"{demo_entities.DEMO_SEED}:core")
        self.demo_cat = demo_entities.catalog()
        self.wh.extend(dict(w) for w in self.demo_cat["warehouses"])
        self.demo_wh_names = {w["name"] for w in self.demo_cat["warehouses"]}
        self.wh_by_name = {w["name"]: w for w in self.wh}
        self.demo_role_days: dict[str, int] = {}             # demo role -> created days ago
        self.demo_db_days: dict[str, int] = {}               # demo database -> created days ago

    def size_at(self, w, ts: dt.datetime) -> str:
        """The size a warehouse ran at, at `ts`: a resized demo warehouse ran at its old size before the resize."""
        if "like" not in w:
            return w["size"]
        from tests.fake_snowflake import demo_compute
        r = demo_compute.RESIZES.get(w["name"])
        if r and ts < _t(self.day(r[0]), *demo_compute.RESIZE_AT):
            return r[1]
        return w["size"]

    def wh_alive(self, w, d) -> bool:
        """False before a demo warehouse was created or after it was dropped; base ones always live."""
        c, x = w.get("created_days"), w.get("dropped_days")
        return not ((c is not None and d < self.day(c)) or (x is not None and d >= self.day(x)))

    def demo_hours_on(self, w) -> range:
        if w["activity"] == 0:
            return range(9, 11)                              # resumed by a monitor or a tool, no queries
        if w["suspend"] == 0 or w["like"] == "WH_IDLE":
            return range(0, 24)
        return {"WH_ETL": range(0, 7), "WH_BI": range(7, 19), "WH_ADHOC": range(8, 19),
                "WH_ADAPTIVE": range(6, 23), "WH_ML": range(9, 18)}[w["like"]]

    def demo_idle(self, w, attributed: float, active: bool, hour: dt.datetime) -> float:
        """Idle credits in one hour of a demo warehouse: what it burns waiting to auto-suspend."""
        rate = RATE[self.size_at(w, hour)]
        if w["like"] == "WH_IDLE" or not active and not attributed:
            return 0.0
        if w["activity"] == 0:
            return rate * min(1.0, 0.1 + w["suspend"] / 3600)
        if w["suspend"] == 0:
            return max(0.0, rate - attributed)              # never suspends: the whole hour is billed
        if not attributed:
            return 0.0
        share = min(0.9, 0.08 + w["suspend"] / 3000) * (1.6 if w["oversized"] else 1.0)
        clusters = 1.5 if w["max"] > 1 else 1.0
        return min(rate * clusters * share, max(0.0, rate * clusters - attributed))

    def _demo_grant(self, privilege, on, name, grantee, age=None, **kw) -> None:
        """A grant made after its grantee role, a granted role and the object (`age` days old) existed."""
        back = self.drng.randint(30, 700)
        caps = [age, self.demo_role_days.get(grantee), self.demo_role_days.get(name) if on == "ROLE" else None]
        caps = [c for c in caps if c is not None]
        if caps:
            back = min(back, max(0, min(caps) - 1))
        self.grant(privilege, on, name, grantee, days_back=back, **kw)

    def demo_users_roles(self) -> None:
        cat, rng = self.demo_cat, self.drng
        for u in cat["users"]:
            self.users.append(u["name"])
            person = u["type"] == "PERSON"
            last = u["last_login_days"]
            self.au("USERS", dict(
                user_id=u["id"], name=u["name"], login_name=u["name"],
                email=f"{u['name'].lower()}@example.com" if person else None, type=u["type"], disabled=u["disabled"],
                snowflake_lock=False, has_password=u["has_password"], must_change_password=False,
                has_mfa=u["has_mfa"] if person else None, ext_authn_duo=False, has_rsa_public_key=u["has_rsa"],
                has_pat=False, has_workload_identity=False,
                last_success_login=_t(self.day(last), 9) if last is not None else None,
                password_last_set_time=(_t(self.day(u["pw_age_days"]), 8) if u["pw_age_days"] < u["created_days"]
                                        else _t(self.day(u["created_days"]), 10, 5)) if u["has_password"] else None,
                created_on=_t(self.day(u["created_days"]), 10), deleted_on=None, owner="USERADMIN",
                default_role=u["default_role"], default_secondary_role=None,
                default_warehouse=f"WH_{u['team']}_{'ADHOC' if person else 'ETL'}", is_from_organization_user=False))
        for r in cat["roles"]:
            self.roles.append(r["name"])
            self.demo_role_days[r["name"]] = rng.randint(200, 1000)
            self.au("ROLES", dict(
                role_id=r["id"], name=r["name"], owner="USERADMIN", role_type="ROLE", owner_role_type="ROLE",
                created_on=_t(self.day(self.demo_role_days[r["name"]]), 9), deleted_on=None, comment=None,
                is_from_organization_user_group=False))
        # READ -> WRITE -> ADMIN -> SYSADMIN per team; service roles under SYSADMIN; TEMP_CONTRACTOR_ROLE orphaned
        for team in cat["teams"]:
            for child, parent in ((f"{team}_READ", f"{team}_WRITE"), (f"{team}_WRITE", f"{team}_ADMIN"),
                                  (f"{team}_ADMIN", "SYSADMIN"), (f"{team}_READ", "SVC_REPORTING_ROLE")):
                self._demo_grant("USAGE", "ROLE", child, parent, granted_by="SECURITYADMIN")
        for child, parent in (("SVC_INGEST_ROLE", "SYSADMIN"), ("SVC_REPORTING_ROLE", "SYSADMIN"),
                              ("SVC_ML_ROLE", "SYSADMIN"), ("DATA_SCIENCE_WRITE", "SVC_ML_ROLE"),
                              ("PLATFORM_WRITE", "SVC_INGEST_ROLE"), ("AUDITOR_ROLE", "SECURITYADMIN")):
            self._demo_grant("USAGE", "ROLE", child, parent, granted_by="SECURITYADMIN")
        self._demo_grant("MONITOR USAGE", "ACCOUNT", ACCOUNT_NAME, "AUDITOR_ROLE", granted_by="ACCOUNTADMIN")
        self._demo_grant("USAGE", "DATABASE_ROLE", "SNOWFLAKE.USAGE_VIEWER", "AUDITOR_ROLE", granted_by="ACCOUNTADMIN")
        # warehouses: owner, team usage, a couple open to PUBLIC
        for w in self.wh:
            if "like" not in w:
                continue
            dropped = w["dropped_days"] is not None
            wage = w["created_days"]
            self._demo_grant("OWNERSHIP", "WAREHOUSE", w["name"], w["owner"], granted_by="SYSADMIN", deleted=dropped,
                             age=wage)
            team = w["team"]
            grantees = {"WH_ETL": [f"{team}_WRITE", "SVC_INGEST_ROLE"], "WH_BI": [f"{team}_READ", "SVC_REPORTING_ROLE"],
                        "WH_ADHOC": [f"{team}_READ"], "WH_ML": [f"{team}_WRITE", "SVC_ML_ROLE"],
                        "WH_IDLE": [f"{team}_READ"], "WH_ADAPTIVE": [f"{team}_READ"]}[w["like"]]
            if w["name"] in ("WH_SANDBOX_GEN2", "WH_LEGACY_REPORTS"):
                grantees = grantees + ["PUBLIC"]
            for r in grantees:
                self._demo_grant("USAGE", "WAREHOUSE", w["name"], r, deleted=dropped, age=wage)
            self._demo_grant("OPERATE", "WAREHOUSE", w["name"], f"{team}_ADMIN", deleted=dropped, age=wage)
        # users get their team roles; one admin per team; service users their service role
        by_team: dict[str, list] = {}
        for u in cat["users"]:
            by_team.setdefault(u["team"], []).append(u)
        for team, us in by_team.items():
            people = [u for u in us if u["type"] == "PERSON"]
            for k, u in enumerate(us):
                roles = [u["default_role"]]
                if u["type"] == "PERSON" and k == 0:
                    roles.append(f"{team}_ADMIN")
                if u["name"].endswith("_INGEST"):
                    roles.append("SVC_INGEST_ROLE")
                if u["name"].endswith("_REPORTING"):
                    roles.append("SVC_REPORTING_ROLE")
                if team == "DATA_SCIENCE" and u["type"] == "PERSON" and k < 3:
                    roles.append("SVC_ML_ROLE")
                if team == "OPS" and people and u is people[-1]:
                    roles.append("TEMP_CONTRACTOR_ROLE")
                if team == "PLATFORM" and people and u is people[-1]:
                    roles.append("AUDITOR_ROLE")
                if team in ("DATA_SCIENCE", "PRODUCT", "MARKETING") and u["type"] == "PERSON":
                    roles.append("PLATFORM_WRITE")           # handed out to unblock dbt: a write role many hold
                for r in roles:
                    back = min(rng.randint(5, max(6, u["created_days"])), self.demo_role_days.get(r, 10 ** 6))
                    self.au("GRANTS_TO_USERS", dict(created_on=_t(self.day(back), 11), role=r, granted_to="USER",
                                                    grantee_name=u["name"], granted_by="USERADMIN"))

    def demo_objects(self) -> None:
        cat, rng = self.demo_cat, self.drng
        GB = 1024 ** 3
        dbs = {d["name"]: d for d in cat["databases"]}
        # a database is older than its schemas, and a schema older than its oldest table
        oldest_db: dict[str, int] = {}
        oldest_schema: dict[tuple, int] = {}
        for t in cat["tables"]:
            oldest_db[t["db"]] = max(oldest_db.get(t["db"], 0), t["created_days"])
            oldest_schema[(t["db"], t["schema"])] = max(oldest_schema.get((t["db"], t["schema"]), 0), t["created_days"])
        for d in cat["databases"]:
            self.dbs[d["name"]] = d["id"]
            age = max(oldest_db.get(d["name"], 0), 250) + rng.randint(20, 150)
            self.demo_db_days[d["name"]] = age
            self.au("DATABASES", dict(
                database_id=d["id"], database_name=d["name"], database_owner=d["owner"],
                is_transient="YES" if d["transient"] else "NO", type="STANDARD", retention_time=d["retention"],
                created=_t(self.day(age), 9), last_altered=_t(self.day(rng.randint(0, 60)), 9),
                owner_role_type="ROLE", object_visibility="PRIVILEGED"))
            self._demo_grant("OWNERSHIP", "DATABASE", d["name"], d["owner"], age=age)
            self._demo_grant("USAGE", "DATABASE", d["name"], f"{d['team']}_READ", age=age)
            info_id = 4500 + d["id"]                         # INFORMATION_SCHEMA ids, clear of the catalog's
            self.schema_id[(d["name"], "INFORMATION_SCHEMA")] = info_id
            self.au("SCHEMATA", dict(
                schema_id=info_id, schema_name="INFORMATION_SCHEMA", catalog_id=d["id"], catalog_name=d["name"],
                schema_owner=None, retention_time=d["retention"], is_transient="YES" if d["transient"] else "NO",
                is_managed_access="NO", created=_t(self.day(age), 9), last_altered=_t(self.day(age), 9),
                schema_type="STANDARD", version_name=None))
        for s in cat["schemas"]:
            d = dbs[s["db"]]
            self.schema_id[(s["db"], s["name"])] = s["id"]
            owner = f"{s['team']}_WRITE" if s["name"] in ("RAW", "STAGING", "SCRATCH") else f"{s['team']}_ADMIN"
            db_age = self.demo_db_days[s["db"]]
            age = rng.randint(oldest_schema.get((s["db"], s["name"]), 30) + 1, db_age)
            self.au("SCHEMATA", dict(
                schema_id=s["id"], schema_name=s["name"], catalog_id=s["db_id"], catalog_name=s["db"],
                schema_owner=owner, retention_time=d["retention"], is_transient="YES" if d["transient"] else "NO",
                is_managed_access="YES" if s["managed"] else "NO", created=_t(self.day(age), 9),
                last_altered=_t(self.day(min(age, rng.randint(0, 90))), 9), owner_role_type="ROLE",
                schema_type="STANDARD", version_name=None))
            self._demo_grant("OWNERSHIP", "SCHEMA", f"{s['db']}.{s['name']}", owner, schema_=s["name"], catalog=s["db"],
                             age=age)
            self._demo_grant("USAGE", "SCHEMA", f"{s['db']}.{s['name']}", f"{s['team']}_READ", schema_=s["name"],
                             catalog=s["db"], age=age)
        for t in cat["tables"]:
            d = dbs[t["db"]]
            is_view = t["type"] in ("VIEW", "MATERIALIZED VIEW")
            nbytes = None if t["type"] == "VIEW" else int(t["gb"] * GB)
            rows = None if t["type"] == "VIEW" else t["rows"]
            owner = f"{t['team']}_WRITE" if t["schema"] in ("RAW", "STAGING", "SCRATCH") else f"{t['team']}_ADMIN"
            ck = "(EVENT_DATE)" if t["clustered"] else ""
            ret = d["retention"]
            trans = "YES" if t["transient"] else "NO"
            altered = min(t["last_altered_days"], t["created_days"])
            entry = dict(id=t["id"], db=t["db"], schema=t["schema"], name=t["name"], type=t["type"], transient=trans,
                         rows=rows, bytes=nbytes, clustering=ck, dynamic="NO", hybrid="NO", iceberg="NO", owner=owner,
                         fqn=f"{t['db']}.{t['schema']}.{t['name']}", demo=True, team=t["team"],
                         last_altered_days=altered, created_days=t["created_days"])
            self.tables.append(entry)
            self.au("TABLES", dict(
                table_id=t["id"], table_name=t["name"], table_schema_id=t["schema_id"], table_schema=t["schema"],
                table_catalog_id=t["db_id"], table_catalog=t["db"], table_owner=owner, table_type=t["type"],
                is_transient=trans, clustering_key=ck or None, auto_clustering_on="YES" if ck else "NO",
                row_count=rows, bytes=nbytes, retention_time=ret, created=_t(self.day(t["created_days"]), 9),
                last_altered=_t(self.day(altered), 9), last_ddl=_t(self.day(max(altered, rng.randint(0, t["created_days"]))), 9),
                last_ddl_by=owner, is_iceberg="NO", is_dynamic="NO", is_hybrid="NO"))
            if t["type"] == "BASE TABLE":
                churn = rng.choice([0.0, 0.002, 0.01, 0.03, 0.08])      # share of the table rewritten per day
                tt = nbytes * churn * min(ret, 30)
                fs = 0 if t["transient"] else nbytes * churn * 7
                self.au("TABLE_STORAGE_METRICS", dict(
                    id=t["id"], table_name=t["name"], table_schema_id=t["schema_id"], table_schema=t["schema"],
                    table_catalog_id=t["db_id"], table_catalog=t["db"], clone_group_id=t["id"], is_transient=trans,
                    active_bytes=nbytes, time_travel_bytes=int(tt), failsafe_bytes=int(fs), retained_for_clone_bytes=0,
                    deleted=False, table_created=_t(self.day(t["created_days"]), 9)))
            if is_view:
                self.au("VIEWS", dict(
                    table_id=t["id"], table_name=t["name"], table_schema_id=t["schema_id"], table_schema=t["schema"],
                    table_catalog_id=t["db_id"], table_catalog=t["db"], table_owner=owner, view_definition="select 1",
                    is_updatable="NO", insertable_into="NO", is_secure="YES" if rng.random() < 0.2 else "NO",
                    created=_t(self.day(t["created_days"]), 9), last_altered=_t(self.day(altered), 9),
                    last_ddl=_t(self.day(altered), 9), last_ddl_by=owner, owner_role_type="ROLE"))
            self._demo_grant("OWNERSHIP", "VIEW" if is_view else "TABLE", entry["fqn"], owner, schema_=t["schema"],
                             catalog=t["db"], age=t["created_days"])

    def demo_db_bytes(self) -> dict:
        """{(database id, name): (database bytes, fail-safe bytes)} of the demo catalog databases, summed from
        TABLE_STORAGE_METRICS: database bytes hold active, Time Travel and clone-retained bytes."""
        names = {d["id"]: d["name"] for d in self.demo_cat["databases"]}
        out: dict = {}
        for r in self.rows.get(("account_usage", "TABLE_STORAGE_METRICS"), []):
            dbid = r.get("table_catalog_id")
            if dbid not in names:
                continue
            key = (dbid, names[dbid])
            b, f = out.get(key, (0, 0))
            out[key] = (b + (r.get("active_bytes") or 0) + (r.get("time_travel_bytes") or 0)
                        + (r.get("retained_for_clone_bytes") or 0), f + (r.get("failsafe_bytes") or 0))
        return out

    def demo_queries(self, profiles: dict, spike_days) -> None:
        """Queries on the demo warehouses: each runs its archetype's profile with its own team's users."""
        from tests.fake_snowflake import demo_entities
        cat, rng = self.demo_cat, self.drng
        users = {u["name"]: u for u in cat["users"]}
        last = {n: (None if u["disabled"] else u["last_login_days"]) for n, u in users.items()}
        plans = []
        for w in self.wh:
            if "like" not in w:
                continue
            team, like = w["team"], w["like"]
            base = profiles[like]
            us = [u for u in cat["users"] if u["team"] == team]
            people = [u["name"] for u in us if u["type"] == "PERSON"]
            writers = [u["name"] for u in us if u["type"] == "PERSON" and u["default_role"].endswith("WRITE")] or people[:2]
            ingest, reporting = f"SVC_{team}_INGEST", f"SVC_{team}_REPORTING"
            pool = {"WH_ETL": [ingest] * 4 + writers[:2], "WH_BI": [reporting] * 3 + people,
                    "WH_ADHOC": people, "WH_ML": people[:4], "WH_IDLE": people[:2],
                    "WH_ADAPTIVE": people + [reporting]}[like]
            t = team.lower()
            tags = {"WH_ETL": [f"airflow:dag_{t}_load", f"airflow:dag_{t}_daily", "dbt", ""],
                    "WH_BI": [f"bi:tableau:{t}_dash", f"bi:looker:{t}_kpis", f"bi:tableau:{t}_weekly", ""],
                    "WH_ML": ["ml:train", f"ml:{t}_features", ""]}.get(like, [""])
            dev = like == "WH_ADHOC" and w["env"] == "dev"
            lo, hi = base["dur"]
            p = dict(base, users=pool, tag=tags, role=f"{team}_READ",
                     role_of={n: users[n]["default_role"] for n in pool},
                     db=f"{team}_{'DEV' if dev else 'PROD'}_DB",
                     schema="SCRATCH" if dev else ("STAGING" if like == "WH_ETL" else "MARTS"),
                     dur=(lo * 0.05, hi * 0.08) if w["oversized"] else (lo, hi))
            plans.append((w, p))
        qn = self.qn
        for d in self.days(DEMO_QUERY_DAYS):
            k = (self.as_of - d).days
            for w, p in plans:
                if not self.wh_alive(w, d) or w["activity"] == 0:
                    continue
                f = demo_entities.day_factor(w["team"], d, k) * w["activity"] * 0.3 * DEMO_VOLUME.get(w["name"], 1.0)
                f *= demo_share(k)
                if not p["weekend"] and not self.is_weekday(d):
                    f *= 0.1
                lo, hi = p["n"]
                n = int(rng.randint(lo, hi) * f + rng.random())
                if n <= 0:
                    continue
                who = [u for u in p["users"] if last[u] is not None and last[u] <= k < users[u]["created_days"]]
                if not who:
                    continue
                for _ in range(n):
                    qn += 1
                    row = self._query_row(w, p, d, rng, qn, who, spike_days)
                    # documented shapes the shared row builder leaves loose: cache share is 0-1, adaptive
                    # statements report size ADAPTIVE, and only writes wait on DML locks
                    cache = row["percentage_scanned_from_cache"] / 100
                    if not (w["suspend"] and w["suspend"] <= 60):
                        cache = 0.5 + 0.45 * cache               # warm: only a 60 s auto-suspend drops the cache often
                    row["percentage_scanned_from_cache"] = round(cache, 4)
                    if w["spill"] < 0.1:                     # a well-sized warehouse spills now and then, a little
                        for c in ("bytes_spilled_to_local_storage", "bytes_spilled_to_remote_storage"):
                            row[c] = int(row[c] * 0.03)
                    if w["type"] == "ADAPTIVE":
                        row["warehouse_size"] = "ADAPTIVE"
                    if row["query_type"] not in DML_LOCK_TYPES:
                        row["transaction_blocked_time"] = 0
                    # a statement shape belongs to its warehouse's workload, not to every warehouse
                    row["query_hash"] = row["query_parameterized_hash"] = f"{row['query_hash']}w{w['id']}"
                    self.q_rows.append(row)
                    self.au("QUERY_HISTORY", row)
                    if (w["like"] in ("WH_BI", "WH_ADHOC") and row["query_type"] == "SELECT"
                            and row["execution_time"] > 60000 and rng.random() < 0.5):
                        self.au("QUERY_ACCELERATION_ELIGIBLE", dict(
                            query_id=row["query_id"], query_text=row["query_text"], start_time=row["start_time"],
                            end_time=row["end_time"], warehouse_name=w["name"], warehouse_size=row["warehouse_size"],
                            eligible_query_acceleration_time=row["execution_time"] / 1000 * 0.6,
                            upper_limit_scale_factor=8, query_hash=row["query_hash"], query_hash_version=2,
                            query_parameterized_hash=row["query_parameterized_hash"],
                            query_parameterized_hash_version=1))
        self.demo_qn = qn

    def demo_access(self, rows: list, obj) -> None:
        """ACCESS_HISTORY and TABLE_DML_HISTORY for the demo queries and tables."""
        rng = self.drng
        pii_cols = ["ID", "NAME", "EMAIL", "PHONE", "ADDRESS"]
        sets: dict[tuple, list] = {}
        for t in self.tables:
            if t.get("demo"):
                sets.setdefault((t["team"], t["db"].endswith("_DEV_DB"), t["schema"]), []).append(t)
        pii = {f"{t['db']}.{t['schema']}.{t['name']}" for t in self.demo_cat["tables"] if t["pii"]}
        wh = self.wh_by_name
        for r in rows:
            if r["execution_status"] != "SUCCESS" or r["query_type"] in ("SHOW", "DESCRIBE", "USE"):
                continue
            if rng.random() > 0.35:
                continue
            w = wh[r["warehouse_name"]]
            dev = r["database_name"].endswith("_DEV_DB")
            schemas = ["SCRATCH"] if dev else (["RAW", "STAGING"] if w["like"] == "WH_ETL" else ["MARTS", "STAGING"])
            pool = [t for s in schemas for t in sets.get((w["team"], dev, s), [])]
            if not pool:
                continue
            reads = rng.sample(pool, min(len(pool), rng.choice([1, 1, 2, 3])))
            base = [obj(t["fqn"], rng.sample(pii_cols, 3) if t["fqn"] in pii else None) for t in reads]
            modified = []
            if r["query_type"] in ("INSERT", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "UPDATE"):
                tgt = rng.choice([t for t in pool if t["type"] == "BASE TABLE"] or pool)
                modified = [{"objectDomain": "Table", "objectName": tgt["fqn"], "objectId": tgt["id"],
                             "columns": [{"columnId": 1, "columnName": "ID", "directSources": [], "baseSources": []}]}]
            self.au("ACCESS_HISTORY", dict(
                query_id=r["query_id"], query_start_time=r["start_time"], user_name=r["user_name"],
                direct_objects_accessed=base, base_objects_accessed=base, objects_modified=modified,
                policies_referenced=[], root_query_id=r["query_id"]))
        for d in self.days(60):
            k = (self.as_of - d).days
            for t in self.tables:
                if not t.get("demo") or t["type"] != "BASE TABLE" or t["last_altered_days"] > 60:
                    continue
                if k < t["last_altered_days"] or k >= t["created_days"] or (t["last_altered_days"] > 3 and d.weekday() != 0):
                    continue                                 # weekly loads; none after the last change or before creation
                hr = _t(d, 2)
                self.au("TABLE_DML_HISTORY", dict(
                    start_time=hr, end_time=hr + dt.timedelta(hours=1), table_id=t["id"], table_name=t["name"],
                    schema_id=self.schema_id[(t["db"], t["schema"])], schema_name=t["schema"],
                    database_id=self.dbs[t["db"]], database_name=t["db"], rows_added=rng.randint(100, 500_000),
                    rows_removed=rng.randint(0, 2000), rows_updated=rng.randint(0, 50_000)))

    def demo_last_logins(self, user_rows: dict, by_user_ip: dict) -> None:
        """A sign-in on each demo user's last login day when no query session made one."""
        seen = {(u, d) for (u, d, _w) in self.sessions}
        for u in self.demo_cat["users"]:
            k = u["last_login_days"]
            if k is None or (u["name"], self.day(k)) in seen:
                continue
            row = user_rows[u["name"]]
            first = "RSA_KEYPAIR" if row["has_rsa_public_key"] else ("PASSWORD" if row["has_password"] else "SAML2_ASSERTION")
            second = "TOTP" if first == "PASSWORD" and row["has_mfa"] else None
            self._sess_id += 1
            sid, d = self._sess_id, self.day(k)
            like = "WH_ADHOC" if u["type"] == "PERSON" else "WH_ETL"
            ctype, app_id, env_app = self.demo_client(u["name"], like)
            cver = app_id.split(" ")[-1]
            ip = by_user_ip[u["name"]]
            at = _t(d, self.drng.randint(7, 11 if k == 0 else 18), self.drng.randint(0, 59), self.drng.randint(0, 59))
            self.au("LOGIN_HISTORY", dict(
                event_id=sid, event_timestamp=at, event_type="LOGIN", user_name=u["name"], client_ip=ip,
                reported_client_type=ctype, reported_client_version=cver, first_authentication_factor=first,
                second_authentication_factor=second, is_success="YES", connection=None,
                login_details=json.dumps({"CLIENT_IP": ip})))
            self.au("SESSIONS", dict(
                session_id=sid, created_on=at + dt.timedelta(seconds=1), user_name=u["name"],
                authentication_method=first, login_event_id=sid, client_application_id=app_id,
                client_environment=json.dumps({"APPLICATION": env_app, "OS": "Linux", "OS_VERSION": "5.4"}),
                is_open="NO", closed_reason=self.demo_closed_reason(u["name"], ctype, like)))

    # client -> (LOGIN_HISTORY.REPORTED_CLIENT_TYPE, SESSIONS.CLIENT_APPLICATION_ID, CLIENT_ENVIRONMENT application)
    DEMO_CLIENTS = {
        "ui": ("SNOWFLAKE_UI", "Snowflake UI 9.31.0", "Snowsight"),
        "dbeaver": ("JDBC_DRIVER", "JDBC 3.19.0", "DBeaver"),
        "looker": ("JDBC_DRIVER", "JDBC 3.16.1", "Looker"),
        "spark": ("JDBC_DRIVER", "JDBC 3.13.30", "Spark"),
        "tableau": ("ODBC_DRIVER", "ODBC 3.4.1", "Tableau"),
        "powerbi": ("ODBC_DRIVER", "ODBC 3.2.0", "PowerBI"),
        "excel": ("ODBC_DRIVER", "ODBC 2.25.12", "EXCEL"),
        "airflow": ("PYTHON_DRIVER", "PythonConnector 3.12.3", "Airflow"),
        "dbt": ("PYTHON_DRIVER", "PythonConnector 3.10.1", "dbt"),
        "jupyter": ("PYTHON_DRIVER", "PythonConnector 3.13.0", "jupyter_notebook"),
        "snowsql": ("SNOWSQL", "SnowSQL 1.3.2", "SnowSQL"),
        "sigma": ("GO_DRIVER", "Go 1.11.1", "Sigma"),
        "terraform": ("GO_DRIVER", "Go 1.10.0", "terraform-provider-snowflake"),
        "dotnet": ("DOTNET_DRIVER", ".NET 4.1.0", "ReportServer"),
        "node": ("JAVASCRIPT_DRIVER", "JavaScript 1.14.0", "internal-api"),
    }
    # warehouse archetype -> (clients of service users, clients of people), with weights
    DEMO_CLIENT_MIX = {
        "WH_ETL": ({"airflow": 5, "dbt": 3, "spark": 1, "terraform": 1}, {"snowsql": 3, "dbeaver": 3, "ui": 4}),
        "WH_BI": ({"tableau": 4, "looker": 3, "powerbi": 2, "dotnet": 1, "node": 1}, {"ui": 5, "excel": 3, "sigma": 2}),
        "WH_ADHOC": ({"node": 1}, {"ui": 6, "dbeaver": 2, "jupyter": 2, "snowsql": 1, "excel": 1}),
        "WH_ML": ({"jupyter": 1}, {"jupyter": 5, "spark": 2, "ui": 2}),
        "WH_ADAPTIVE": ({"node": 2, "tableau": 1}, {"ui": 4, "powerbi": 2}),
        "WH_IDLE": ({"dotnet": 1}, {"ui": 1}),
    }

    def demo_client(self, user: str, like: str) -> tuple[str, str, str]:
        """A demo session's client: what such a user runs on such a warehouse."""
        svc, people = self.DEMO_CLIENT_MIX[like]
        mix = svc if user.startswith("SVC_") else people
        name = self.drng.choices(list(mix), weights=list(mix.values()))[0]
        return self.DEMO_CLIENTS[name]

    ADMIN_ROLES = {"ACCOUNTADMIN", "SECURITYADMIN", "SYSADMIN", "USERADMIN", "ORGADMIN"}

    def demo_closed_reason(self, user: str, ctype: str, like: str) -> str:
        """Why a closed demo session ended, from the documented CLOSED_REASON values."""
        if not hasattr(self, "_demo_admins"):
            self._demo_admins = {r["grantee_name"] for r in self.rows.get(("account_usage", "GRANTS_TO_USERS"), [])
                                 if r["role"] in self.ADMIN_ROLES or r["role"].endswith("_ADMIN")}
        if user.startswith("SVC_"):
            mix = {"LOGOUT": 12, "ABANDONED": 2}
            if like == "WH_ETL":
                mix["TASK_COMPLETED"] = 2
            if ctype == "ODBC_DRIVER":
                mix["OAUTH_CONSENT_REVOKED"] = 0.3            # a BI tool's OAuth grant withdrawn
        elif ctype == "SNOWFLAKE_UI":
            mix = {"ABANDONED": 6, "LOGOUT": 3, "SFC_FORCED_LOGOUT": 0.05}
        else:
            mix = {"LOGOUT": 6, "ABANDONED": 3}
        if user in self._demo_admins:
            mix["FORCED_LOGOUT"] = 0.8                        # an admin's session ended by SECURITYADMIN
        return self.drng.choices(list(mix), weights=list(mix.values()))[0]

    def demo_show(self) -> None:
        """SHOW WAREHOUSES, RESOURCE MONITORS and DATABASES rows for the demo account."""
        rng = self.drng
        for w in self.wh:
            if "like" not in w or w["dropped_days"] is not None:
                continue                                     # a dropped warehouse is gone from SHOW
            always_on = w["suspend"] == 0 or w["like"] == "WH_IDLE"
            gen2 = w["constraint"] == "STANDARD_GEN_2"
            self.show("warehouses", _wh_show(dict(
                name=w["name"], state="STARTED" if always_on else "SUSPENDED", type=w["type"],
                size="ADAPTIVE" if w["type"] == "ADAPTIVE" else w["size"],
                min_cluster_count=w["min"], max_cluster_count=w["max"], started_clusters=1 if always_on else 0,
                running=0, queued=0, is_default="N", is_current="N",
                auto_suspend=w["suspend"] or None, auto_resume="true", available="", provisioning="", quiescing="",
                other="", created_on=_t(self.day(w["created_days"]), 9), resumed_on=_t(self.day(rng.randint(0, 3)), 9),
                updated_on=_t(self.day(min(w["created_days"], rng.randint(1, 120))), 9), owner=w["owner"], comment="",
                enable_query_acceleration="true" if w["qas"] else "false",
                query_acceleration_max_scale_factor=8 if w["qas"] else 0, resource_monitor=w["monitor"] or "null",
                scaling_policy="ECONOMY" if w["max"] > 2 else "STANDARD", owner_role_type="ROLE",
                resource_constraint=w["constraint"], generation="2" if gen2 else "1")))
        # used credits = what the monitored warehouses metered since the first of the month; quotas set so the
        # biggest spender is over (and suspended), the next near its quota, the rest comfortably under
        cycle = _t(self.as_of.replace(day=1))
        monitored = {w["name"]: w["monitor"] for w in self.wh if "like" in w and w["monitor"]}
        used: dict[str, float] = {}
        for r in self.rows.get(("account_usage", "WAREHOUSE_METERING_HISTORY"), []):
            mon = monitored.get(r["warehouse_name"])
            if mon and cycle <= r["start_time"] < self.now.replace(hour=0):
                used[mon] = used.get(mon, 0.0) + r["credits_used"]
        ranked = sorted({m for m in monitored.values()}, key=lambda m: -used.get(m, 0.0))
        for i, name in enumerate(sorted(ranked)):
            u = used.get(name, 0.0)
            pos = ranked.index(name)
            share = 1.06 if pos == 0 else (0.93 if pos == 1 else rng.choice([0.25, 0.4, 0.55, 0.7]))
            quota = max(50.0, round(u / share / 50) * 50)
            if pos == 0:
                quota = max(50.0, (u // 50) * 50)            # rounded down, so it stays over
            self.show("resource_monitors", dict(
                name=name, credit_quota=quota, used_credits=round(u, 1),
                remaining_credits=round(max(0.0, quota - u), 1), level="WAREHOUSE", frequency="MONTHLY",
                start_time=cycle, end_time=None, notify_at=rng.choice(["75", "80,90", "50,75,90"]),
                suspend_at=100 if pos == 0 else rng.choice([100, 100, None]),
                suspend_immediately_at=110 if pos == 0 else rng.choice([110, None]),
                created_on=_t(self.day(rng.randint(100, 500)), 9), owner="ACCOUNTADMIN", comment="",
                notify_users=None))
        for d in self.demo_cat["databases"]:
            self.show("databases", dict(
                created_on=_t(self.day(self.demo_db_days[d["name"]]), 9), name=d["name"], is_default="N", is_current="N", origin="",
                owner=d["owner"], comment="", options="TRANSIENT" if d["transient"] else "",
                retention_time=str(d["retention"]), kind="STANDARD", owner_role_type="ROLE"))


def load(con, as_of, demo: bool = False) -> None:
    """Fill the fake SNOWFLAKE tables for an account as of `as_of` (the first day not yet complete).

    `demo` adds the larger demo account (demo_data.py) on top; the tests never use it."""
    world = World(as_of, demo)
    errors = []
    for (schema_name, view), rows in world.rows.items():
        try:
            _insert(con, schema_name, view, rows)
        except KeyError as exc:
            errors.append(str(exc))
    if errors:
        raise KeyError("; ".join(errors))
