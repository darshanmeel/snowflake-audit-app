"""Demo area "queries": the special query patterns the Queries pages look for, per team.

The core pass already runs ordinary queries on every demo warehouse. This adds, on the demo warehouses only:
dashboards refreshed over and over (same hash, cache misses, queuing), dbt projects, spilling and full-scan
jobs, big result downloads, compile-heavy generated SQL, lock waits, failures by error code, a metadata
polling tool, long runs and timeouts, retries, a spread of client tools, query insights, aggregate history
and table pruning history. Attributed credits only fill each warehouse-hour's metered idle, so attribution
never exceeds the bill.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import random

from tests.fake_snowflake import demo_ai_perf
from tests.fake_snowflake import demo_security
from tests.fake_snowflake.data import RATE, demo_share
from tests.fake_snowflake.demo_pipelines import STREAMS

GB = 1024 ** 3

# client tool -> (REPORTED_CLIENT_TYPE, CLIENT_APPLICATION_ID, CLIENT_ENVIRONMENT APPLICATION)
CLIENTS = {
    "tableau": ("ODBC_DRIVER", "ODBC 3.1.4", "Tableau"),
    "powerbi": ("ODBC_DRIVER", "ODBC 3.0.2", "PowerBI"),
    "looker": ("JDBC_DRIVER", "JDBC 3.14.4", "Looker"),
    "sigma": ("GO_DRIVER", "Go 1.7.1", "Sigma"),
    "dbt": ("PYTHON_DRIVER", "PythonConnector 3.10.1", "dbt"),
    "airflow": ("PYTHON_DRIVER", "PythonConnector 3.6.0", "Airflow"),
    "jupyter": ("PYTHON_DRIVER", "PythonConnector 3.12.3", "jupyter_notebook"),
    "notebook": ("SNOWFLAKE_UI", "Snowflake Notebook 1.0", "Snowflake Notebooks"),
    "snowsight": ("SNOWFLAKE_UI", "Snowflake Web App 2.0", "Snowsight"),
    "streamlit": ("PYTHON_DRIVER", "PythonConnector 3.12.3", "Streamlit"),
    "fivetran": ("JDBC_DRIVER", "JDBC 3.13.30", "Fivetran"),
    "excel": ("ODBC_DRIVER", "ODBC 2.25.0", "EXCEL"),
    "snowsql": ("SNOWSQL", "SnowSQL 1.3.2", "SnowSQL"),
    "census": ("GO_DRIVER", "Go 1.10.0", "Census"),
    "monitor": ("GO_DRIVER", "Go 1.6.0", "infra-monitor"),
    "spark": ("SPARK_CONNECTOR", "SparkConnector 2.16.0", "Spark"),
    "hex": ("PYTHON_DRIVER", "PythonConnector 3.11.0", "Hex"),
}

QDAYS = 185                # statements cover the 90-day window and the one before it, like the metering
DAYS = 95                  # insights and pruning history: the 90-day window and a margin
META = ("SHOW", "DESCRIBE", "USE", "SET", "ALTER_SESSION", "BEGIN_TRANSACTION", "COMMIT", "ROLLBACK", "DESCRIBE_QUERY")
NO_SCAN = META + ("LIST_FILES", "REMOVE_FILES", "GET_FILES", "EXECUTE_TASK", "ALTER_WAREHOUSE_SUSPEND",
                  "ALTER_WAREHOUSE_RESUME", "DROP", "CREATE_SCHEMA", "RENAME_TABLE", "CREATE_TASK", "ALTER_TASK",
                  "CREATE_STREAM", "GRANT", "REVOKE", "CREATE_ROLE", "CREATE_TABLE", "CREATE_VIEW",
                  "ALTER_TABLE_MODIFY_COLUMN", "TRUNCATE_TABLE", "EXPLAIN", "UNKNOWN")
# QUERY_TYPE -> (OBJECT_MODIFIED_BY_DDL operationType, objectDomain)
DDL = {"CREATE_TABLE": ("CREATE", "Table"), "CREATE_VIEW": ("REPLACE", "View"), "DROP": ("DROP", "Table"),
       "ALTER_TABLE_MODIFY_COLUMN": ("ALTER", "Table"), "RENAME_TABLE": ("ALTER", "Table"),
       "CREATE_SCHEMA": ("CREATE", "Schema"), "CREATE_TASK": ("CREATE", "Task"), "ALTER_TASK": ("ALTER", "Task"),
       "CREATE_STREAM": ("CREATE", "Stream"), "GRANT": ("GRANT", "Table"), "REVOKE": ("REVOKE", "Table"),
       "CREATE_ROLE": ("CREATE", "Role"), "ALTER_WAREHOUSE_SUSPEND": ("ALTER", "Warehouse"),
       "ALTER_WAREHOUSE_RESUME": ("ALTER", "Warehouse")}
# procedures the demo's CALLs run; the first three come from demo_storage, the last two are added here
PROCS = {"FINANCE": "FINANCE_PROD_DB.STAGING.P_CLOSE_MONTH", "PLATFORM": "PLATFORM_PROD_DB.STAGING.P_PURGE_STAGES",
         "OPS": "OPS_PROD_DB.STAGING.P_REBUILD_DW", "DATA_SCIENCE": "DATA_SCIENCE_PROD_DB.MARTS.P_BUILD_FEATURES",
         "RISK": "RISK_PROD_DB.MARTS.P_SCORE_PORTFOLIO"}


def h(*parts) -> str:
    return hashlib.md5("|".join(str(p) for p in parts).encode()).hexdigest()


class Gen:
    def __init__(self, b):
        self.b, self.w, self.rng = b, b.w, b.rng
        self.wh = {w["name"]: w for w in self.w.wh if "like" in w}
        self.ids = {w["id"] for w in self.wh.values()}
        self.users = {u["name"]: u for u in b.cat["users"]}
        self.ip = {u: f"203.0.113.{10 + i}" for i, u in enumerate(self.w.users)}
        self.urow = {r["name"]: r for r in self.w.rows[("account_usage", "USERS")] if r["user_id"] >= 50000}
        self.tables = [t for t in self.w.tables if t.get("demo")]
        # idle credits left in each metered warehouse-hour: what new attributed queries may use
        self.room, self.mrow = {}, {}
        for r in self.w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]:
            if r["warehouse_id"] in self.ids:
                key = (r["warehouse_id"], r["start_time"])
                self.mrow[key] = r
                self.room[key] = r["credits_used_compute"] - (r.get("credits_attributed_compute_queries") or 0)
        self.n = 0
        self.sess: dict = {}
        self.rows: list[dict] = []
        self.ins = 7_000_000

    # ---- people and tables -------------------------------------------------------------------------------
    def people(self, team: str, k: int, writers: bool = False) -> list[str]:
        out = [u["name"] for u in self.users.values()
               if u["team"] == team and u["type"] == "PERSON" and not u["disabled"]
               and u["last_login_days"] is not None and u["last_login_days"] <= k and u["created_days"] > k
               and (not writers or u["default_role"].endswith("WRITE"))]
        return out or ([] if not writers else self.people(team, k))

    def svc(self, team: str, kind: str = "INGEST") -> str:
        return f"SVC_{team}_{kind}"

    def big_tables(self, team: str, n: int = 3, schema: str | None = None) -> list[dict]:
        ts = [t for t in self.tables if t["team"] == team and t["type"] == "BASE TABLE"
              and not t["db"].endswith("_DEV_DB") and (schema is None or t["schema"] == schema)]
        return sorted(ts, key=lambda t: -(t["bytes"] or 0))[:n]

    # ---- sessions -----------------------------------------------------------------------------------------
    def session(self, user: str, start: dt.datetime, client: str) -> int:
        """One session per user, day and client; it signs in just before its first statement."""
        key = (user, start.date(), client)
        s = self.sess.get(key)
        if s is None:
            self.w._sess_id += 1
            s = self.sess[key] = [self.w._sess_id, start]
        elif start < s[1]:
            s[1] = start
        return s[0]

    def flush_sessions(self) -> None:
        mfa: dict[str, tuple] = {}
        for (user, _d, client), (sid, first) in sorted(self.sess.items(), key=lambda kv: kv[1][0]):
            row = self.urow.get(user, {})
            first_f = "RSA_KEYPAIR" if row.get("has_rsa_public_key") else ("PASSWORD" if row.get("has_password") else "SAML2_ASSERTION")
            second, second_id = None, None
            if first_f == "PASSWORD" and row.get("has_mfa"):    # the user's enrolled method, as demo_security wrote it
                if user not in mfa:
                    mfa[user] = demo_security.second_factor(self.w, user)
                second, second_id = mfa[user]
            ctype, app_id, app = CLIENTS[client]
            when = first.replace(microsecond=0) - dt.timedelta(seconds=2 + sid % 40)
            self.b.au("LOGIN_HISTORY", event_id=sid, event_timestamp=when, event_type="LOGIN", user_name=user,
                      client_ip=self.ip.get(user, "203.0.113.200"), reported_client_type=ctype,
                      reported_client_version=app_id.split(" ")[-1], first_authentication_factor=first_f,
                      second_authentication_factor=second, second_authentication_factor_id=second_id,
                      is_success="YES", connection=None,
                      login_details=json.dumps({"CLIENT_IP": self.ip.get(user, "203.0.113.200")}))
            self.b.au("SESSIONS", session_id=sid, created_on=when, user_name=user, authentication_method=first_f,
                      login_event_id=sid, client_application_id=app_id,
                      client_environment=json.dumps({"APPLICATION": app, "OS": "Linux", "OS_VERSION": "5.15"}),
                      is_open="NO", closed_reason=None)

    # ---- attribution inside the metered idle ---------------------------------------------------------------
    def _need(self, w, t0: dt.datetime, exec_ms: int) -> list:
        rate = RATE[self.w.size_at(w, t0)] * (1.5 if w["max"] > 1 else 1)
        out, t, end = [], t0, t0 + dt.timedelta(milliseconds=exec_ms)
        while t < end:
            hour = t.replace(minute=0, second=0, microsecond=0)
            nxt = min(end, hour + dt.timedelta(hours=1))
            out.append(((w["id"], hour), rate * (nxt - t).total_seconds() / 3600))
            t = nxt
        return out

    def fits(self, w, t0, exec_ms) -> bool:
        return all(self.room.get(k, 0) >= c for k, c in self._need(w, t0, exec_ms))

    def take(self, w, t0, exec_ms) -> float:
        total = 0.0
        for k, c in self._need(w, t0, exec_ms):
            self.room[k] -= c
            r = self.mrow[k]
            if r.get("credits_attributed_compute_queries") is not None:
                r["credits_attributed_compute_queries"] += c
            total += c
        return total

    def metered(self, w, t0, exec_ms) -> bool:
        """Every hour the run spans has a metering row: the warehouse was billed while it ran."""
        return all(k in self.mrow for k, _ in self._need(w, t0, exec_ms))

    def take_shared(self, w, t0, exec_ms) -> float:
        """A long run shares its hours with other queries: it gets what is left of each hour."""
        total = 0.0
        for k, c in self._need(w, t0, exec_ms):
            got = max(0.0, min(c, self.room.get(k, 0)))
            self.room[k] -= got
            r = self.mrow[k]
            if r.get("credits_attributed_compute_queries") is not None:
                r["credits_attributed_compute_queries"] += got
            total += got
        return total

    def slot(self, w, d: dt.date, hours, exec_ms: int, pre_ms: int = 0, shrink: bool = True, tries: int = 12):
        """(start, exec_ms) with room for the run on day d within `hours`, else None."""
        for i in range(tries):
            hr = self.rng.choice(list(hours))
            start = dt.datetime(d.year, d.month, d.day, hr, self.rng.randint(0, 50), self.rng.randint(0, 59))
            ms = exec_ms if not shrink or i < tries // 2 else int(exec_ms * 0.4)
            if self.fits(w, start + dt.timedelta(milliseconds=pre_ms), ms):
                return start, ms
        return None

    # ---- one QUERY_HISTORY row ------------------------------------------------------------------------------
    def q(self, wname, user, client, start, qtype, exec_ms, *, attribute=True, comp_ms=None, queued=0, prov=0,
          blocked=0, status="SUCCESS", err=None, msg=None, phash=None, qhash=None, tag=None, text=None,
          scanned=None, ptotal=None, pscanned=None, local=0, remote=0, result=0, rows=None, cache=None, cs=None,
          retry=0, retry_cause=None, db=None, schema=None, role=None, written=None, no_wh=False,
          shared=False, cached=False, client_gen=False, parent=None, fault=0, child_wait=0) -> dict:
        self.n += 1
        w = self.wh[wname]
        u = self.users.get(user)
        team = w["team"]
        db = db or f"{team}_PROD_DB"
        schema = schema or ("STAGING" if w["like"] == "WH_ETL" else "MARTS")
        comp_ms = comp_ms if comp_ms is not None else self.rng.randint(40, 900)
        pre = comp_ms + queued + prov + blocked
        total = pre + exec_ms
        meta = qtype in META
        if scanned is None:
            scanned = 0 if qtype in NO_SCAN or cached else int(exec_ms * self.rng.uniform(2e4, 4e5))
        if ptotal is None and scanned:
            ptotal = max(1, int(scanned / (16 * 1024 ** 2)) * 4)
            pscanned = max(1, int(ptotal * self.rng.uniform(0.02, 0.35)))
        credits = 0.0
        t0 = start + dt.timedelta(milliseconds=pre)
        if shared and attribute and w["attributed"]:
            credits = self.take_shared(w, t0, exec_ms)
        elif attribute and not no_wh and not meta and exec_ms >= 100 and w["attributed"] and self.fits(w, t0, exec_ms):
            credits = self.take(w, t0, exec_ms)               # no room in the metered hour: left unattributed
        phash = phash or h(wname, qtype, self.n % 23)
        if rows is None:
            rows = int(self.rng.uniform(1, 5e4)) if scanned or cached else 0
        ok_select = qtype == "SELECT" and status == "SUCCESS"
        # a reused result is read from the result cache; any other result set is written to one
        to_result = 0 if cached or not ok_select else (result or rows * 120)
        from_result = (result or rows * 120) if cached and ok_select else 0
        row = dict(
            query_id=f"01dq-{self.n:07d}", query_text=text or f"{qtype.lower().replace('_', ' ')} /* demo */",
            database_id=self.w.dbs.get(db), database_name=db, schema_id=self.w.schema_id.get((db, schema)),
            schema_name=schema, query_type=qtype, session_id=self.session(user, start, client),
            user_name=user, role_name=role or (u["default_role"] if u else f"{team}_READ"),
            warehouse_id=None if no_wh else w["id"], warehouse_name=None if no_wh else wname,
            warehouse_size=None if no_wh else self.w.size_at(w, start), warehouse_type=None if no_wh else w["type"],
            cluster_number=None if no_wh else 1, query_tag=tag, execution_status=status, error_code=err,
            error_message=msg, start_time=start, end_time=start + dt.timedelta(milliseconds=total),
            total_elapsed_time=total, compilation_time=comp_ms, execution_time=exec_ms,
            queued_provisioning_time=prov, queued_repair_time=0, queued_overload_time=queued,
            transaction_blocked_time=blocked, child_queries_wait_time=child_wait, query_retry_time=retry,
            query_retry_cause=retry_cause, fault_handling_time=fault, bytes_scanned=scanned,
            percentage_scanned_from_cache=cache if cache is not None else (round(self.rng.uniform(0, 0.9), 3) if scanned else 0.0),
            bytes_written=written if written is not None else (int(scanned * 0.1) if qtype in (
                "INSERT", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "UPDATE", "DELETE") else 0),
            bytes_written_to_result=to_result, bytes_read_from_result=from_result, rows_produced=rows,
            rows_inserted=int(scanned / 400) if qtype in ("INSERT", "COPY", "MERGE", "CREATE_TABLE_AS_SELECT") else 0,
            rows_updated=int(scanned / 4000) if qtype in ("MERGE", "UPDATE") else 0,
            rows_deleted=int(scanned / 9000) if qtype == "DELETE" else 0, rows_unloaded=int(scanned / 500) if qtype == "UNLOAD" else 0,
            bytes_deleted=0, partitions_scanned=pscanned, partitions_total=ptotal,
            bytes_spilled_to_local_storage=local, bytes_spilled_to_remote_storage=remote,
            bytes_sent_over_the_network=int(scanned * 0.01),
            credits_used_cloud_services=cs if cs is not None else self.rng.uniform(0.00002, 0.0006) * (1 + comp_ms / 2000),
            query_load_percent=None if no_wh else self.rng.randint(10, 100),
            query_acceleration_bytes_scanned=0, query_acceleration_partitions_scanned=0,
            query_hash=qhash or phash, query_hash_version=2, query_parameterized_hash=phash,
            query_parameterized_hash_version=1, transaction_id=60_000_000 + self.n, role_type="ROLE",
            user_type=(u["type"] if u else "PERSON"), is_client_generated_statement=client_gen,
            user_database_id=str(self.w.dbs.get(db)), user_schema_id=str(self.w.schema_id.get((db, schema))))
        self.b.au("QUERY_HISTORY", **row)
        row["_parent"] = parent
        if credits:
            self.attribution(row, credits)
        row["_credits"] = credits
        self.rows.append(row)
        return row

    def attribution(self, row, credits) -> None:
        """A QUERY_ATTRIBUTION_HISTORY row; a stored procedure's children carry its id as parent and root."""
        self.b.au("QUERY_ATTRIBUTION_HISTORY", query_id=row["query_id"], parent_query_id=row["_parent"],
                  root_query_id=row["_parent"] or row["query_id"], warehouse_id=row["warehouse_id"],
                  warehouse_name=row["warehouse_name"], query_hash=row["query_hash"],
                  query_parameterized_hash=row["query_parameterized_hash"], query_tag=row["query_tag"],
                  user_name=row["user_name"], start_time=row["start_time"], end_time=row["end_time"],
                  credits_attributed_compute=credits, credits_used_query_acceleration=None)

    def insight(self, row, itype, opportunity=True):
        self.ins += 1
        self.b.au("QUERY_INSIGHTS", start_time=row["start_time"], end_time=row["end_time"],
                  total_elapsed_time=row["total_elapsed_time"], query_id=row["query_id"], query_hash=row["query_hash"],
                  query_parameterized_hash=row["query_parameterized_hash"], warehouse_id=str(row["warehouse_id"]),
                  warehouse_name=row["warehouse_name"], insight_instance_id=self.ins, insight_type_id=itype,
                  message=["See the query profile for the operator this insight refers to."],
                  suggestions=["Review the statement and its warehouse."], is_opportunity=opportunity,
                  insight_topic="performance")

    def share(self, k: int) -> float:
        """Statement volume k days back, as in the core pass: a steady, modest growth."""
        return demo_share(k)

    def keep(self, k: int) -> bool:
        return self.rng.random() < demo_share(k)

    def days(self, n: int, weekdays: bool = False):
        for k in range(n, 0, -1):
            d = self.b.back(k)
            if weekdays and d.weekday() >= 5:
                continue
            yield k, d

    def alive(self, wname, k) -> bool:
        w = self.wh[wname]
        return w["created_days"] > k and (w["dropped_days"] is None or k > w["dropped_days"])


# ---- patterns ------------------------------------------------------------------------------------------------
# Warehouses whose dashboards queue at capacity, and how hard: the morning rush (8-11h) is the peak.
QUEUE_PRONE = {"WH_SALES_BI": 1.0, "WH_MARKETING_BI": 0.8, "WH_RISK_BI": 0.6, "WH_PRODUCT_BI": 0.6,
               "WH_DATA_SCIENCE_BI": 0.5, "WH_FINANCE_BI": 0.4}


def _queue_shape(wname: str, start: dt.datetime, drawn: int, n: int) -> int:
    """The queued-at-capacity ms for one dashboard query: peaks 8-11h, light at lunch, rare after.

    Its own generator, so the demo's shared random sequence (and every other page) stays as it was."""
    weight = QUEUE_PRONE.get(wname)
    if not weight:
        return drawn
    rng = random.Random(f"queue:{wname}:{start.isoformat()}:{n}")
    hr = start.hour
    chance = 0.9 if 8 <= hr <= 10 else 0.6 if hr == 11 else 0.12 if 12 <= hr <= 14 else 0.03
    chance *= weight * (1.3 if start.weekday() == 0 else 0.8 if start.weekday() == 4 else 1.0)
    if rng.random() >= chance:
        return 0
    peak = 8 <= hr <= 11
    return int(rng.uniform(20000, 150000) if peak else rng.uniform(2000, 25000))


def dashboards(g: Gen) -> None:
    """BI dashboards refreshed through the day: the same tiles again and again, some tagged, some not."""
    # wh, team, client, dashboard, tag style, runs/day, credits per run, tile weights
    boards = [
        ("WH_DATA_SCIENCE_BI", "DATA_SCIENCE", "tableau", "ds_model_monitoring", "json", 8, 1.7, [0.75, 0.15, 0.1]),
        ("WH_SALES_BI", "SALES", "looker", "pipeline_overview", "looker", 12, 0.25, [0.5, 0.3, 0.2]),
        ("WH_MARKETING_BI", "MARKETING", "powerbi", None, None, 10, 0.3, [0.6, 0.4]),
        ("WH_FINANCE_BI", "FINANCE", "tableau", "month_end_close", "plain", 6, 0.08, [0.5, 0.5]),
        ("WH_PRODUCT_BI", "PRODUCT", "sigma", "wb-7f3a21", "sigma", 10, 0.05, [0.4, 0.3, 0.3]),
        ("WH_STREAMLIT_APPS", "PRODUCT", "streamlit", "ops_cockpit", "json", 20, 0.01, [0.5, 0.5]),
        ("WH_RISK_BI", "RISK", "tableau", "credit_risk_daily", "json", 4, 0.4, [0.7, 0.3]),
        ("WH_OPS_BI", "OPS", "excel", None, None, 3, 0.02, [1.0]),
        ("WH_PLATFORM_BI", "PLATFORM", "looker", "cost_explorer", "looker", 5, 0.12, [0.5, 0.5]),
    ]
    for wname, team, client, dash, style, per_day, cr, tiles in boards:
        w = g.wh[wname]
        rate = RATE[w["size"]] * (1.5 if w["max"] > 1 else 1)
        user = g.svc(team, "REPORTING")
        for k, d in g.days(QDAYS, weekdays=True):
            if not g.alive(wname, k):
                continue
            month_end = d.day >= 27 or d.day <= 2
            n = round(per_day * (2 if month_end and team in ("FINANCE", "SALES") else 1) * g.share(k))
            if client in ("tableau", "powerbi", "looker", "excel"):
                # the driver's own metadata calls when the dashboard connects
                st = dt.datetime(d.year, d.month, d.day, 7, g.rng.randint(0, 20), g.rng.randint(0, 59))
                kinds = ["SHOW", "DESCRIBE"] + (["DESCRIBE_QUERY"] if client == "looker" else ["SHOW"])
                for i, qt in enumerate(kinds):
                    g.q(wname, user, client, st + dt.timedelta(seconds=i), qt, 25, comp_ms=40, client_gen=True,
                        phash=h("drv", wname, qt), cs=g.rng.uniform(0.00005, 0.0003))
            for _ in range(n):
                tile = g.rng.choices(range(len(tiles)), weights=tiles)[0]
                ph = h("dash", wname, dash, tile)
                exec_ms = int(cr * (tiles[tile] * len(tiles)) / rate * 3.6e6 * g.rng.uniform(0.7, 1.3))
                queued = 0
                if wname == "WH_SALES_BI":
                    queued = int(g.rng.uniform(30000, 120000) if (month_end or d.weekday() == 0) else g.rng.uniform(0, 9000))
                got = g.slot(w, d, range(7, 19), exec_ms, pre_ms=queued)
                if not got:
                    continue
                start, ms = got
                queued = _queue_shape(wname, start, queued, g.n)
                tag, text = None, f"select /* tile {tile} */ ..."
                if style == "json":
                    tag = json.dumps({"tool": CLIENTS[client][2].lower(), "dashboard": dash, "tile": tile})
                elif style == "plain":
                    tag = f"[{dash}]"
                elif style == "looker":
                    text = "-- Looker Query Context '{\"user_id\":12,\"dashboard_id\":\"%s\",\"history_slug\":\"a%d\"}'\nselect ..." % (dash, tile)
                elif style == "sigma":
                    text = '-- Sigma Σ {"workbook-id":"%s","url":"https://app.example.com/wb/%s"}\nselect ...' % (dash, dash)
                hit = wname == "WH_STREAMLIT_APPS" and g.rng.random() < 0.5
                row = g.q(wname, user, client, start, "SELECT", 12 if hit else ms, attribute=not hit, phash=ph,
                          tag=tag, text=text, queued=0 if hit else queued, cached=hit, comp_ms=g.rng.randint(15, 60) if hit else None,
                          cache=0.0 if hit else round(g.rng.uniform(0, 0.15), 3),
                          result=int(g.rng.uniform(1e4, 5e6)), rows=g.rng.randint(5, 4000))
                if queued > 60000 and k <= DAYS and g.rng.random() < 0.5:
                    g.insight(row, "QUERY_INSIGHT_QUEUED_OVERLOAD")


def dbt_projects(g: Gen) -> None:
    """Nightly dbt runs per project: models with their own cost, plus dbt's metadata statements."""
    projects = [
        ("sales_mart", "WH_SALES_ETL", "SALES", [("fct_orders", "table", 7.5), ("dim_customers", "incremental", 1.0),
                                                ("fct_pipeline", "incremental", 0.6), ("snap_accounts", "snapshot", 0.25),
                                                ("stg_orders", "view", 0.0)]),
        ("product_analytics", "WH_PRODUCT_ETL", "PRODUCT", [("fct_events", "incremental", 1.3), ("dim_features", "table", 0.3),
                                                            ("stg_events", "view", 0.0)]),
        ("finance_core", "WH_FINANCE_ETL", "FINANCE", [("fct_ledger", "incremental", 0.4), ("dim_accounts", "table", 0.15)]),
    ]
    kinds = {"table": "CREATE_TABLE_AS_SELECT", "incremental": "MERGE", "snapshot": "MERGE", "view": "CREATE_VIEW"}
    for project, wname, team, models in projects:
        w = g.wh[wname]
        rate = RATE[w["size"]]
        user = g.svc(team, "INGEST")
        for k, d in g.days(QDAYS):
            inv = h(project, d)[:12]
            full = d.day == 1                                  # monthly full refresh: every model rebuilt
            for model, mat, cr in models:
                node = f"model.{project}.{model}"
                tag = json.dumps({"app": "dbt", "node_id": node, "invocation_id": inv, "project_name": project,
                                  "target_name": "prod", "materialized": mat, "dbt_version": "1.8.7"})
                hr = range(1, 6)
                for meta in ("SHOW", "DESCRIBE"):
                    st = dt.datetime(d.year, d.month, d.day, 1, g.rng.randint(0, 59), g.rng.randint(0, 59))
                    g.q(wname, user, "dbt", st, meta, 30, phash=h(project, meta), tag=tag, comp_ms=60,
                        cs=g.rng.uniform(0.0002, 0.0012), client_gen=True)
                if mat == "view":
                    st = dt.datetime(d.year, d.month, d.day, 1, g.rng.randint(0, 59))
                    g.q(wname, user, "dbt", st, "CREATE_VIEW", 150, phash=h(node), tag=tag)
                    continue
                exec_ms = int(cr * (4 if full else 1) / rate * 3.6e6 * g.rng.uniform(0.8, 1.2))
                got = g.slot(w, d, hr, exec_ms)
                if not got:
                    continue
                start, ms = got
                fail = mat == "incremental" and g.rng.random() < 0.02
                big = model == "fct_orders"
                parts = 48_000 if big else None
                row = g.q(wname, user, "dbt", start, kinds[mat], ms, phash=h(node), tag=tag,
                          text='/* {"app": "dbt", "node_id": "%s", "invocation_id": "%s"} */ create or replace ...' % (node, inv),
                          status="FAIL" if fail else "SUCCESS",
                          err=100090 if fail else None,
                          msg="Duplicate row detected during DML action Row Values: [N, \"x\"]" if fail else None,
                          ptotal=parts, pscanned=int(parts * g.rng.uniform(0.9, 1.0)) if big else None,
                          remote=int(g.rng.uniform(1, 3) * GB) if big and g.rng.random() < 0.4 else 0,
                          local=int(g.rng.uniform(20, 60) * GB) if big and g.rng.random() < 0.3 else 0)
                if big and k <= DAYS:
                    g.insight(row, "QUERY_INSIGHT_NO_FILTER_ON_TOP_OF_TABLE_SCAN")
                for meta in ("BEGIN_TRANSACTION", "ROLLBACK" if fail else "COMMIT"):
                    g.q(wname, user, "dbt", row["end_time"], meta, 20, phash=h(project, meta), tag=tag, comp_ms=10,
                        cs=0.00005)


def dbt_ci(g: Gen) -> None:
    """CI builds: many short statements whose compile time outweighs their run time."""
    wname, user = "WH_DBT_CI", "SVC_PLATFORM_INGEST"
    w = g.wh[wname]
    for k, d in g.days(QDAYS):
        if not g.alive(wname, k):
            continue
        for run in range(2):
            inv = h("ci", d, run)[:12]
            for s in range(20):
                shape = s % 4
                node = f"model.platform_ci.m{shape}"
                tag = json.dumps({"app": "dbt", "node_id": node, "invocation_id": inv, "project_name": "platform_ci",
                                  "target_name": "ci", "materialized": "view"})
                exec_ms = g.rng.randint(2000, 8000)
                got = g.slot(w, d, range(0, 7), exec_ms, shrink=False, tries=4)
                start = got[0] if got else dt.datetime(d.year, d.month, d.day, 2, g.rng.randint(0, 59))
                g.q(wname, user, "dbt", start, "CREATE_TABLE_AS_SELECT" if shape == 0 else "CREATE_VIEW",
                    exec_ms, attribute=bool(got), comp_ms=g.rng.randint(11000, 20000), phash=h("ci", shape), tag=tag,
                    text="create or replace view ... /* " + "x" * 1500 + " */",
                    cs=g.rng.uniform(0.0004, 0.0012))


def generated_sql(g: Gen) -> None:
    """A BI tool's generated SQL with huge IN lists: compilation dominates."""
    for wname, team, per_day, comp, ph in (("WH_SALES_BI", "SALES", 25, (40000, 60000), "gen-sales"),
                                           ("WH_RISK_BI", "RISK", 3, (2000, 5000), "gen-risk")):
        w = g.wh[wname]
        for k, d in g.days(QDAYS, weekdays=True):
            ppl = g.people(team, k)
            if not ppl:
                continue
            for _ in range(round(per_day * g.share(k))):
                exec_ms = g.rng.randint(1500, 6000)
                c = g.rng.randint(*comp)
                got = g.slot(w, d, range(8, 18), exec_ms, pre_ms=c, shrink=False, tries=3)
                start = got[0] if got else dt.datetime(d.year, d.month, d.day, g.rng.randint(8, 17), g.rng.randint(0, 59))
                g.q(wname, g.rng.choice(ppl), "sigma", start, "SELECT", exec_ms, attribute=bool(got), comp_ms=c,
                    phash=h(ph), text="select ... where id in (" + "?, " * 1800 + "?)",
                    cs=g.rng.uniform(0.001, 0.003))


def spills(g: Gen) -> None:
    """Undersized jobs that spill to local and remote storage, with memory retries and node faults."""
    # Out-of-memory retries are QUERY_RETRY_TIME; node and network faults are FAULT_HANDLING_TIME.
    jobs = [  # wh, team, client, user kind, runs/day, exec minutes, local GB, remote GB, hours, share, cause, odds
        ("WH_DATA_SCIENCE_ETL", "DATA_SCIENCE", "airflow", "INGEST", 2, 45, (80, 150), (15, 35), range(0, 24), 0.3,
         "Out of memory", 0.6),
        ("WH_RISK_ETL", "RISK", "airflow", "INGEST", 1, 20, (8, 20), (1.5, 3.0), range(0, 7), 0.15, "Out of memory", 0.12),
        ("WH_DS_TRAIN", "DATA_SCIENCE", "notebook", "PERSON", 1, 25, (2, 6), (0.0, 0.2), range(9, 18), 0.0, None, 0),
        ("WH_OPS_ETL", "OPS", "airflow", "INGEST", 1, 8, (1, 3), (0, 0), range(0, 7), 0.08, "fault", 0.6),
    ]
    for wname, team, client, kind, per_day, mins, lgb, rgb, hours, retry, cause, odds in jobs:
        w = g.wh[wname]
        ph = h("spill", wname)
        for k, d in g.days(QDAYS):
            if not g.alive(wname, k) or not g.keep(k):
                continue
            user = g.svc(team) if kind == "INGEST" else (g.people(team, k) or [None])[0]
            if not user:
                continue
            for _ in range(per_day):
                got = g.slot(w, d, hours, int(mins * 60000 * g.rng.uniform(0.8, 1.2)))
                if not got:
                    continue
                start, ms = got
                remote = int(g.rng.uniform(*rgb) * GB) if rgb[1] else 0
                lost = int(ms * retry * g.rng.uniform(0.6, 1.4)) if retry and g.rng.random() < odds else 0
                row = g.q(wname, user, client, start, "INSERT" if kind == "INGEST" else "CALL", ms, phash=ph,
                          scanned=int(g.rng.uniform(150, 300) * GB), local=int(g.rng.uniform(*lgb) * GB), remote=remote,
                          retry=lost if cause != "fault" else 0, retry_cause=cause if lost and cause != "fault" else None,
                          fault=lost if cause == "fault" else 0)
                if remote and k <= DAYS and g.rng.random() < 0.6:
                    g.insight(row, "QUERY_INSIGHT_REMOTE_SPILLAGE")


def full_scans(g: Gen) -> None:
    """Statements that read most partitions of large tables, and ones that prune well."""
    shapes = [  # wh, team, client, runs/day, credits/run, partitions, scan share, qtype, insight
        ("WH_FINANCE_ADHOC", "FINANCE", "snowsight", 3, 0.6, 12_000, (0.88, 0.99), "SELECT", "QUERY_INSIGHT_LIKE_WITH_LEADING_WILDCARD"),
        ("WH_MARKETING_ADHOC", "MARKETING", "hex", 1, 3.0, 30_000, (0.9, 1.0), "SELECT", "QUERY_INSIGHT_NO_FILTER_ON_TOP_OF_TABLE_SCAN"),
        ("WH_OPS_BI", "OPS", "excel", 1, 0.05, 2_000, (0.85, 0.95), "SELECT", None),
        ("WH_SALES_ADHOC", "SALES", "snowsight", 2, 0.4, 9_000, (0.01, 0.05), "SELECT", "QUERY_INSIGHT_FILTER_WITH_CLUSTERING_KEY"),
        ("WH_PRODUCT_ETL", "PRODUCT", "airflow", 1, 0.8, 25_000, (0.85, 0.97), "DELETE", "QUERY_INSIGHT_UNSELECTIVE_FILTER"),
    ]
    for wname, team, client, per_day, cr, parts, share, qtype, itype in shapes:
        w = g.wh[wname]
        rate = RATE[w["size"]]
        hours = range(1, 6) if w["like"] == "WH_ETL" else range(8, 18)
        ph = h("scan", wname)
        for k, d in g.days(QDAYS, weekdays=w["like"] != "WH_ETL"):
            users = [g.svc(team)] if w["like"] == "WH_ETL" else g.people(team, k)
            if not users:
                continue
            for _ in range(per_day):
                if not g.keep(k):
                    continue
                got = g.slot(w, d, hours, int(cr / rate * 3.6e6 * g.rng.uniform(0.7, 1.3)))
                if not got:
                    continue
                start, ms = got
                row = g.q(wname, g.rng.choice(users), client, start, qtype, ms, phash=h(ph, qtype),
                          qhash=h(ph, start), ptotal=parts, pscanned=int(parts * g.rng.uniform(*share)),
                          scanned=int(parts * g.rng.uniform(*share) * 16 * 1024 ** 2), rows=int(g.rng.uniform(1e3, 5e5)))
                if itype and k <= DAYS and g.rng.random() < 0.5:
                    g.insight(row, itype, opportunity=itype != "QUERY_INSIGHT_FILTER_WITH_CLUSTERING_KEY")


def large_results(g: Gen) -> None:
    """Raw rows pulled into notebooks, extracts and spreadsheets."""
    pulls = [  # wh, team, client, user kind, runs per day, result GB, minutes
        ("WH_DATA_SCIENCE_ADHOC", "DATA_SCIENCE", "jupyter", "PERSON", 2, (25, 35), 20),
        ("WH_MARKETING_BI", "MARKETING", "tableau", "REPORTING", 1, (2.5, 4.0), 6),
        ("WH_FINANCE_BI", "FINANCE", "excel", "PERSON", 0.5, (1.0, 1.6), 3),
        ("WH_REVERSE_ETL", "MARKETING", "census", "REPORTING", 1, (0.2, 0.5), 4),
    ]
    for wname, team, client, kind, per_day, rgb, mins in pulls:
        w = g.wh[wname]
        hours = range(1, 6) if w["like"] == "WH_ETL" else range(8, 18)
        ph = h("pull", wname)
        for k, d in g.days(QDAYS, weekdays=True):
            if g.rng.random() > per_day * g.share(k):
                continue
            user = g.svc(team, "REPORTING") if kind == "REPORTING" else (g.people(team, k) or [None])[0]
            if not user:
                continue
            for _ in range(max(1, int(per_day))):
                got = g.slot(w, d, hours, int(mins * 60000 * g.rng.uniform(0.8, 1.2)))
                if not got:
                    continue
                start, ms = got
                res = int(g.rng.uniform(*rgb) * GB)
                row = g.q(wname, user, client, start, "SELECT", ms, phash=ph, result=res, rows=int(res / 110),
                          scanned=int(res * g.rng.uniform(1.5, 4)), tag=None)
                if client == "jupyter" and k <= DAYS and g.rng.random() < 0.4:
                    g.insight(row, "QUERY_INSIGHT_EXPLODING_JOIN")


def long_runs(g: Gen) -> None:
    """Multi-hour statements: a weekly backfill, a slow scoring job, a runaway query and timeouts."""
    def run(wname, d, hours, ms, **kw):
        w = g.wh[wname]
        for hr in hours:
            start = dt.datetime(d.year, d.month, d.day, hr, g.rng.randint(0, 40))
            if g.metered(w, start + dt.timedelta(seconds=1), ms):
                return g.q(wname, start=start, exec_ms=ms, shared=True, comp_ms=1000, **kw)
        return None

    for k, d in g.days(QDAYS):
        if d.weekday() == 6:                                  # weekly backfill, 9-10 hours
            run("WH_DATA_SCIENCE_ETL", d, (6, 7, 8), int(g.rng.uniform(9, 10) * 3.6e6), user="SVC_DATA_SCIENCE_INGEST",
                client="airflow", qtype="INSERT", phash=h("backfill_features"), local=int(40 * GB))
        run("WH_DATA_SCIENCE_ETL", d, (19, 20), int(g.rng.uniform(1.2, 1.8) * 3.6e6), user="SVC_DATA_SCIENCE_INGEST",
            client="airflow", qtype="MERGE", phash=h("score_customers"))
    # a runaway cross join on the always-on X-Small, canceled after 26 hours
    pl = g.people("PLATFORM", 12)
    if pl:
        row = run("WH_PLATFORM_ADHOC", g.b.back(12), (9, 10, 11), int(26 * 3.6e6), user=pl[0], client="snowsight",
                  qtype="SELECT", status="FAIL", err=604, msg="SQL execution canceled", phash=h("runaway"))
        if row:
            g.insight(row, "QUERY_INSIGHT_JOIN_WITH_NO_JOIN_CONDITION")
    # statement timeouts at one hour on the finance ad-hoc warehouse
    n = 0
    for k, d in g.days(QDAYS, weekdays=True):
        ppl = g.people("FINANCE", k)
        if n >= 48 or not ppl or g.rng.random() > 0.35 * g.share(k):
            continue
        if run("WH_FINANCE_ADHOC", d, g.rng.sample(range(8, 17), 9), 3_600_000, user=g.rng.choice(ppl),
               client="snowsight", qtype="SELECT", status="FAIL", err=630,
               msg="Statement reached its statement or warehouse timeout of 3,600 second(s) and was canceled.",
               phash=h("ledger_recon_all")):
            n += 1


def locks(g: Gen) -> None:
    """Concurrent writers on one table: blocked statements and the lock waits behind them.

    Mostly TABLE locks, some with two or three blockers; also a task's STREAM lock, a PARTITION lock on a
    clustered table held by automatic clustering, and ROW locks on a hybrid table."""
    def lock(blocked, lock_type, obj_id, obj_name, db, schema, wait, blockers):
        req = blocked["start_time"] + dt.timedelta(milliseconds=blocked["compilation_time"])
        g.b.au("LOCK_WAIT_HISTORY", object_id=obj_id, object_name=obj_name, lock_type=lock_type,
               schema_id=0 if lock_type == "ROW" else g.w.schema_id[(db, schema)],
               schema_name=None if lock_type == "ROW" else schema, database_id=g.w.dbs[db], database_name=db,
               query_id=blocked["query_id"], transaction_id=blocked["transaction_id"], requested_at=req,
               acquired_at=req + dt.timedelta(milliseconds=wait),
               blocker_queries=[{"is_snowflake": False, "query_id": x["query_id"], "transaction_id": x["transaction_id"]}
                                if x else {"is_snowflake": True, "query_id": "", "transaction_id": ""} for x in blockers])

    cases = [  # team, wh, per day, blocked seconds, recorded
        ("FINANCE", "WH_FINANCE_ETL", 3, (900, 2400), True),
        ("SALES", "WH_SALES_ETL", 1, (120, 360), True),
        ("MARKETING", "WH_MARKETING_ETL", 0.2, (20, 60), True),
        ("PRODUCT", "WH_PRODUCT_ETL", 0.3, (30, 200), False),
    ]
    for team, wname, per_day, secs, recorded in cases:
        tbl = g.big_tables(team, 1, "STAGING")[0]
        for k, d in g.days(QDAYS):
            if g.rng.random() > per_day * g.share(k):
                continue
            for _ in range(max(1, int(per_day * g.share(k)))):
                hr = g.rng.randint(1, 5)
                st = dt.datetime(d.year, d.month, d.day, hr, g.rng.randint(0, 40), g.rng.randint(0, 59))
                blocker = g.q(wname, g.svc(team), "airflow", st, "MERGE", g.rng.randint(60000, 300000),
                              phash=h("lock-writer-a", team), attribute=False)
                blockers = [blocker]
                if team in ("FINANCE", "SALES") and g.rng.random() < 0.2:      # a pile-up behind two or three writers
                    for j in range(g.rng.randint(1, 2)):
                        blockers.append(g.q(wname, g.svc(team), "airflow", st + dt.timedelta(seconds=2 + j),
                                            "INSERT", g.rng.randint(30000, 120000), attribute=False,
                                            phash=h("lock-writer-d", team)))
                wait = int(g.rng.uniform(*secs) * 1000)
                bst = st + dt.timedelta(seconds=g.rng.randint(5, 50))
                blocked = g.q(wname, g.svc(team), "dbt", bst, "UPDATE", g.rng.randint(20000, 90000), blocked=wait,
                              phash=h("lock-writer-b", team), attribute=False)
                if recorded:
                    lock(blocked, "TABLE", tbl["id"], tbl["name"], tbl["db"], tbl["schema"], wait, blockers)
                if team == "FINANCE" and g.rng.random() < 0.08:
                    g.q(wname, g.svc(team), "dbt", bst + dt.timedelta(minutes=1), "DELETE", 0, attribute=False,
                        status="FAIL", err=625, scanned=0,
                        msg="Statement 'N' has locked table 'N' in transaction N and this lock has not yet been released.",
                        phash=h("lock-writer-c", team))
    # a task consuming a stream waits for a second consumer that read the same stream first
    i = next(i for i, s in enumerate(STREAMS) if s[0] == "OPS_TICKETS")
    sfx, team = STREAMS[i][0], STREAMS[i][1]
    for k, d in g.days(QDAYS):
        if g.rng.random() > 0.15 * g.share(k):
            continue
        st = dt.datetime(d.year, d.month, d.day, 4, g.rng.randint(0, 40))
        first = g.q("WH_OPS_ETL", g.svc(team), "airflow", st, "MERGE", g.rng.randint(30000, 90000), attribute=False,
                    phash=h("stream-consumer-a"))
        wait = g.rng.randint(15000, 80000)
        blocked = g.q("WH_OPS_ETL", g.svc(team), "airflow", st + dt.timedelta(seconds=10), "INSERT",
                      g.rng.randint(10000, 40000), blocked=wait, attribute=False, phash=h("stream-consumer-b"))
        lock(blocked, "STREAM", 90000 + i, f"S_{sfx}", f"{team}_PROD_DB", "STAGING", wait, [first])
    # partition locks: a DELETE on a clustered table waits for automatic clustering
    ct = sorted([t for t in g.tables if t["clustering"] and t["type"] == "BASE TABLE" and t["team"] == "SALES"]
                or [t for t in g.tables if t["clustering"] and t["type"] == "BASE TABLE"], key=lambda t: t["id"])
    if ct:
        tbl, wname = ct[0], next(n for n, w in g.wh.items() if w["team"] == ct[0]["team"] and w["like"] == "WH_ETL")
        for k, d in g.days(QDAYS):
            if g.rng.random() > 0.1 * g.share(k):
                continue
            st = dt.datetime(d.year, d.month, d.day, 3, g.rng.randint(0, 50))
            wait = g.rng.randint(5000, 45000)
            blocked = g.q(wname, g.svc(tbl["team"]), "airflow", st, "DELETE", g.rng.randint(5000, 30000), blocked=wait,
                          attribute=False, phash=h("partition-delete"), db=tbl["db"], schema=tbl["schema"])
            lock(blocked, "PARTITION", tbl["id"], tbl["name"], tbl["db"], tbl["schema"], wait, [None])
    # row locks on the hybrid table behind the app: two sessions updating the same rows
    for k, d in g.days(QDAYS, weekdays=True):
        if g.rng.random() > 0.25 * g.share(k):
            continue
        st = dt.datetime(d.year, d.month, d.day, g.rng.randint(9, 17), g.rng.randint(0, 59))
        first = g.q("WH_STREAMLIT_APPS", g.svc("PRODUCT", "REPORTING"), "streamlit", st, "UPDATE", g.rng.randint(200, 900),
                    attribute=False, scanned=int(2e5), phash=h("ht-update"))
        wait = g.rng.randint(300, 4000)
        blocked = g.q("WH_STREAMLIT_APPS", g.svc("PRODUCT", "REPORTING"), "streamlit", st + dt.timedelta(milliseconds=150),
                      "UPDATE", g.rng.randint(100, 600), blocked=wait, attribute=False, scanned=int(2e5),
                      phash=h("ht-update"))
        lock(blocked, "ROW", 46221, "ROW", "PRODUCT_PROD_DB", "MARTS", wait, [first])


def failures(g: Gen) -> None:
    """Failed statements with a spread of error codes, from a broken DAG down to one-off typos."""
    # a broken DAG retrying every few minutes for three days
    for k in (8, 7, 6):
        d = g.b.back(k)
        for i in range(0, 1440, 4):
            st = dt.datetime(d.year, d.month, d.day) + dt.timedelta(minutes=i, seconds=g.rng.randint(0, 59))
            g.q("WH_MARKETING_ETL", "SVC_MARKETING_INGEST", "airflow", st, "INSERT", 0, attribute=False, scanned=0,
                status="FAIL", err=2003, comp_ms=g.rng.randint(80, 300),
                msg="SQL compilation error: Object 'MARKETING_PROD_DB.RAW.CAMPAIGNS_V2' does not exist or not authorized.",
                phash=h("dag_campaigns_v2"))
    for k, d in g.days(QDAYS):
        # COPY rejecting bad values most nights
        for _ in range(round(g.rng.choice([0, 2, 3, 5, 6, 8]) * g.share(k))):
            st = dt.datetime(d.year, d.month, d.day, 2, g.rng.randint(0, 59))
            g.q("WH_SALES_ETL", "SVC_SALES_INGEST", "fivetran", st, "COPY", g.rng.randint(500, 3000), attribute=False,
                status="FAIL", err=100038, msg="Numeric value 'N/A' is not recognized", phash=h("copy_orders"))
        # a reverse-ETL sync with no warehouse set in its session
        if g.rng.random() < 0.5 * g.share(k):
            for _ in range(g.rng.randint(1, 3)):
                st = dt.datetime(d.year, d.month, d.day, g.rng.randint(8, 18), g.rng.randint(0, 59))
                g.q("WH_REVERSE_ETL", "SVC_MARKETING_REPORTING", "census", st, "SELECT", 0, attribute=False, scanned=0,
                    status="FAIL", err=606, no_wh=True,
                    msg="No active warehouse selected in the current session. Select an active warehouse with the 'use warehouse' command.",
                    phash=h("census_sync"))
        # internal errors: Snowflake opened an incident for the statement
        if g.rng.random() < 0.04 * g.share(k):
            wname = g.rng.choice(["WH_PRODUCT_ETL", "WH_SALES_ETL", "WH_PLATFORM_ETL"])
            team = g.wh[wname]["team"]
            st = dt.datetime(d.year, d.month, d.day, g.rng.randint(0, 6), g.rng.randint(0, 59))
            g.q(wname, g.svc(team), "airflow", st, "MERGE", g.rng.randint(2000, 90000), attribute=False,
                status="INCIDENT", err=603, phash=h("incident", wname),
                msg="SQL execution internal error: Processing aborted due to error 300010:N; incident N.")
        if d.weekday() >= 5:
            continue
        for team, wname in (("SALES", "WH_SALES_ADHOC"), ("FINANCE", "WH_FINANCE_ADHOC"), ("RISK", "WH_RISK_ADHOC"),
                            ("DATA_SCIENCE", "WH_DATA_SCIENCE_ADHOC")):
            ppl = g.people(team, k)
            if not ppl:
                continue
            for err, msg, p in ((904, "SQL compilation error: error line N at position N invalid identifier 'X'", 0.6),
                                (3001, "SQL access control error: Insufficient privileges to operate on table 'X'", 0.3),
                                (2140, "SQL compilation error: Unknown function X", 0.1),
                                (1003, "SQL compilation error: syntax error line N at position N unexpected 'X'.", 0.5),
                                (604, "SQL execution canceled", 0.5)):
                if g.rng.random() < p * g.share(k):
                    st = dt.datetime(d.year, d.month, d.day, g.rng.randint(9, 17), g.rng.randint(0, 59))
                    # a statement that does not parse has no known type
                    g.q(wname, g.rng.choice(ppl), "snowsight", st, "UNKNOWN" if err == 1003 else "SELECT",
                        0 if err != 604 else g.rng.randint(5000, 60000),
                        attribute=err == 604, scanned=0 if err != 604 else None, status="FAIL", err=err, msg=msg,
                        phash=h("adhoc_err", err, team))
        # out of memory on the undersized feature warehouse, after a long run
        if g.rng.random() < 0.15 * g.share(k):
            w = g.wh["WH_DATA_SCIENCE_ETL"]
            got = g.slot(w, d, range(0, 24), int(g.rng.uniform(20, 40) * 60000), shrink=False)
            if got:
                g.q("WH_DATA_SCIENCE_ETL", "SVC_DATA_SCIENCE_INGEST", "airflow", got[0], "CREATE_TABLE_AS_SELECT", got[1],
                    status="INCIDENT", err=300005, msg="Processing aborted due to error 300005:N; incident N.",
                    local=int(60 * GB), remote=int(20 * GB), phash=h("feature_wide_join"))


def metadata_poller(g: Gen) -> None:
    """A monitoring tool that polls SHOW / DESCRIBE / USE all day on the always-on X-Small."""
    types = ["SHOW"] * 5 + ["DESCRIBE", "USE", "SET", "ALTER_SESSION"]
    for k, d in g.days(QDAYS):
        for _ in range(round(g.rng.randint(190, 250) * g.share(k))):
            st = dt.datetime(d.year, d.month, d.day, g.rng.randint(0, 23), g.rng.randint(0, 59), g.rng.randint(0, 59))
            qt = g.rng.choice(types)
            g.q("WH_PLATFORM_ADHOC", "SVC_PLATFORM_REPORTING", "monitor", st, qt, g.rng.randint(5, 80), comp_ms=g.rng.randint(20, 400),
                phash=h("poll", qt), cs=g.rng.uniform(0.006, 0.013), db="PLATFORM_PROD_DB", schema="MARTS")


def call(g: Gen, wname, user, client, start, ms, attribute=True) -> dict:
    """A stored procedure: its child statements carry the cost, the CALL itself only a small share."""
    w = g.wh[wname]
    ph = h("call", wname)
    parts = [g.rng.uniform(0.5, 1.5) for _ in range(g.rng.randint(2, 4))]
    comp = g.rng.randint(100, 600)
    row = g.q(wname, user, client, start, "CALL", ms, attribute=False, comp_ms=comp, phash=ph,
              scanned=0, child_wait=int(ms * 0.9))
    t = start + dt.timedelta(milliseconds=comp + int(ms * 0.05))
    for i, p in enumerate(parts):
        cms = int(ms * 0.9 * p / sum(parts))
        qt = ("SELECT", "MERGE", "INSERT", "CREATE_TABLE_AS_SELECT")[(i + int(ph[:2], 16)) % 4]
        g.q(wname, user, client, t, qt, max(50, cms - 80), attribute=attribute, comp_ms=60, parent=row["query_id"],
            phash=h("call-child", wname, i))
        t += dt.timedelta(milliseconds=cms)
    own = int(ms * 0.03)                              # the procedure's own work between its statements
    t0 = start + dt.timedelta(milliseconds=comp)
    if attribute and own >= 100 and w["attributed"] and g.fits(w, t0, own):
        row["_credits"] = g.take(w, t0, own)
        g.attribution(row, row["_credits"])
    return row


def other_types(g: Gen) -> None:
    """The rest of the statement mix: loads, unloads, deletes, procedures, apps and admin work."""
    # procedures the DATA_SCIENCE and RISK CALLs run; the others come from demo_storage
    for team, lang, rt in (("DATA_SCIENCE", "PYTHON", "3.11"), ("RISK", "PYTHON", "3.10")):
        db, sch, name = PROCS[team].split(".")
        g.b.au("PROCEDURES", procedure_catalog_id=g.w.dbs[db], procedure_catalog=db,
               procedure_schema_id=g.w.schema_id[(db, sch)], procedure_schema=sch, procedure_name=name,
               procedure_owner=f"{team}_ADMIN", argument_signature="()", procedure_language=lang, runtime_version=rt,
               created=g.b.ts(g.rng.randint(200, 400), 9), last_altered=g.b.ts(g.rng.randint(10, 60), 9))
    plan = [  # wh, team, user kind, client, qtype, per day, exec seconds, hours, extra
        ("WH_PLATFORM_ETL", "PLATFORM", "INGEST", "fivetran", "MERGE", 3, (10, 40), range(0, 7), {}),
        ("WH_PLATFORM_ETL", "PLATFORM", "INGEST", "fivetran", "PUT_FILES", 2, (1, 3), range(0, 7), {}),
        ("WH_PLATFORM_ETL", "PLATFORM", "INGEST", "fivetran", "LIST_FILES", 2, (0.2, 1), range(0, 7), {"no_wh": True}),
        ("WH_PLATFORM_ETL", "PLATFORM", "INGEST", "fivetran", "REMOVE_FILES", 1, (0.3, 2), range(0, 7), {"no_wh": True}),
        ("WH_PLATFORM_ETL", "PLATFORM", "INGEST", "airflow", "COPY", 2, (20, 90), range(0, 7), {}),
        ("WH_MARKETING_ETL", "MARKETING", "INGEST", "airflow", "COPY", 1, (15, 60), range(0, 7), {}),
        ("WH_FINANCE_ETL", "FINANCE", "INGEST", "airflow", "UNLOAD", 1, (30, 90), range(0, 7), {}),
        ("WH_FINANCE_ETL", "FINANCE", "INGEST", "airflow", "GET_FILES", 1, (2, 8), range(5, 8), {"no_wh": True}),
        ("WH_OPS_ETL", "OPS", "INGEST", "airflow", "DELETE", 1, (20, 60), range(0, 7), {}),
        ("WH_OPS_ETL", "OPS", "INGEST", "airflow", "TRUNCATE_TABLE", 0.3, (1, 2), range(0, 7), {}),
        ("WH_DS_FEATURES", "DATA_SCIENCE", "PERSON", "notebook", "CALL", 1, (120, 600), range(9, 18), {}),
        ("WH_RISK_MODELS", "RISK", "PERSON", "spark", "CALL", 0.5, (60, 300), range(9, 18), {}),
        ("WH_STREAMLIT_APPS", "PRODUCT", "REPORTING", "streamlit", "EXECUTE_STREAMLIT", 4, (1, 4), range(7, 19), {}),
        ("WH_REVERSE_ETL", "MARKETING", "INGEST", "census", "MULTI_TABLE_INSERT", 0.5, (20, 60), range(0, 7), {}),
        ("WH_SANDBOX_GEN2", "PRODUCT", "PERSON", "snowsql", "CREATE_TABLE", 0.6, (1, 5), range(8, 19), {}),
        ("WH_SANDBOX_GEN2", "PRODUCT", "PERSON", "snowsql", "DROP", 0.4, (0.1, 1), range(8, 19), {}),
        ("WH_PLATFORM_DEV", "PLATFORM", "PERSON", "snowsql", "ALTER_TABLE_MODIFY_COLUMN", 0.3, (1, 3), range(8, 19), {}),
        ("WH_PLATFORM_DEV", "PLATFORM", "PERSON", "snowsql", "RENAME_TABLE", 0.1, (0.1, 1), range(8, 19), {}),
        ("WH_PLATFORM_DEV", "PLATFORM", "PERSON", "snowsql", "CREATE_SCHEMA", 0.05, (0.1, 1), range(8, 19), {}),
        ("WH_SALES_DEV", "SALES", "PERSON", "snowsight", "EXPLAIN", 0.4, (0.2, 1), range(8, 19), {}),
        ("WH_SALES_DEV", "SALES", "PERSON", "snowsight", "DROP", 0.15, (0.1, 1), range(8, 19), {}),
        ("WH_FINANCE_DEV", "FINANCE", "PERSON", "snowsight", "CREATE_TABLE", 0.2, (1, 4), range(8, 19), {}),
    ]
    for wname, team, kind, client, qtype, per_day, secs, hours, extra in plan:
        w = g.wh[wname]
        for k, d in g.days(QDAYS):
            if not g.alive(wname, k):
                continue
            rate = per_day * g.share(k)
            n = int(rate) + (1 if g.rng.random() < rate % 1 else 0)
            if kind == "PERSON":
                if d.weekday() >= 5:
                    continue
                ppl = g.people(team, k)
                if not ppl:
                    continue
            for _ in range(n):
                user = g.rng.choice(ppl) if kind == "PERSON" else g.svc(team, kind)
                ms = int(g.rng.uniform(*secs) * 1000)
                if qtype in NO_SCAN or extra.get("no_wh"):
                    st = dt.datetime(d.year, d.month, d.day, g.rng.choice(list(hours)), g.rng.randint(0, 59))
                    g.q(wname, user, client, st, qtype, ms, attribute=False, phash=h("mix", wname, qtype), **extra)
                    continue
                got = g.slot(w, d, hours, ms, tries=4)
                start = got[0] if got else dt.datetime(d.year, d.month, d.day, g.rng.choice(list(hours)), g.rng.randint(0, 59))
                if qtype == "CALL":
                    call(g, wname, user, client, start, got[1] if got else ms, attribute=bool(got))
                else:
                    g.q(wname, user, client, start, qtype, got[1] if got else ms, attribute=bool(got),
                        phash=h("mix", wname, qtype), **extra)
    # scheduled procedures on the ETL warehouses: month-end close, a weekly purge and a weekly rebuild
    for wname, team, when in (("WH_FINANCE_ETL", "FINANCE", lambda d: d.day in (1, 2)),
                              ("WH_PLATFORM_ETL", "PLATFORM", lambda d: d.weekday() == 6),
                              ("WH_OPS_ETL", "OPS", lambda d: d.weekday() == 5)):
        w = g.wh[wname]
        for k, d in g.days(QDAYS):
            if not when(d) or not g.alive(wname, k):
                continue
            got = g.slot(w, d, range(2, 6), int(g.rng.uniform(5, 20) * 60000), tries=6)
            if got:
                call(g, wname, g.svc(team), "airflow", got[0], got[1])
    # everyday exploration in the worksheets
    for wname, team in (("WH_SALES_ADHOC", "SALES"), ("WH_FINANCE_ADHOC", "FINANCE"), ("WH_RISK_ADHOC", "RISK"),
                        ("WH_DATA_SCIENCE_ADHOC", "DATA_SCIENCE")):
        w = g.wh[wname]
        for k, d in g.days(QDAYS, weekdays=True):
            ppl = g.people(team, k)
            for _ in range(round(g.rng.randint(3, 8) * g.share(k)) if ppl else 0):
                ms = int(g.rng.uniform(0.5, 25) * 1000)
                got = g.slot(w, d, range(8, 19), ms, tries=3)
                start = got[0] if got else dt.datetime(d.year, d.month, d.day, g.rng.randint(8, 18), g.rng.randint(0, 59))
                g.q(wname, g.rng.choice(ppl), "snowsight", start, "SELECT", ms, attribute=bool(got),
                    phash=h("explore", wname, g.rng.randint(0, 30)))
    # admin statements with no warehouse: grants, roles, tasks, streams and warehouse switches
    for k, d in g.days(QDAYS):
        if d.weekday() >= 5:
            continue
        ppl = g.people("PLATFORM", k)
        if not ppl:
            continue
        if g.rng.random() < 0.3 * g.share(k):
            st = dt.datetime(d.year, d.month, d.day, g.rng.randint(9, 17), g.rng.randint(0, 59))
            for qt in ("GRANT", "REVOKE", "CREATE_ROLE"):
                if g.rng.random() < 0.5:
                    g.q("WH_PLATFORM_ADHOC", ppl[0], "snowsight", st, qt, 120, no_wh=True, scanned=0,
                        role="SECURITYADMIN", phash=h("admin", qt))
        for qt, odds, role in (("EXECUTE_TASK", 0.5, None), ("ALTER_TASK", 0.25, None), ("CREATE_TASK", 0.05, None),
                               ("CREATE_STREAM", 0.03, None), ("ALTER_WAREHOUSE_RESUME", 0.2, "SYSADMIN"),
                               ("ALTER_WAREHOUSE_SUSPEND", 0.3, "SYSADMIN")):
            if g.rng.random() < odds * g.share(k):
                st = dt.datetime(d.year, d.month, d.day, g.rng.randint(9, 17), g.rng.randint(0, 59))
                g.q("WH_PLATFORM_ADHOC", g.rng.choice(ppl), "snowsight", st, qt, g.rng.randint(80, 400), no_wh=True,
                    scanned=0, role=role, phash=h("admin", qt))
    # a migration backfill run as SYSADMIN before the warehouse was dropped
    w = g.wh["WH_TEMP_MIGRATION"]
    ppl = g.people("PLATFORM", 30)
    for k, d in g.days(QDAYS):
        if not g.alive("WH_TEMP_MIGRATION", k) or not ppl:
            continue
        for _ in range(3):
            got = g.slot(w, d, range(0, 7), int(g.rng.uniform(5, 15) * 60000))
            if got:
                g.q("WH_TEMP_MIGRATION", ppl[0], "snowsql", got[0], "INSERT", got[1], role="SYSADMIN",
                    phash=h("migration_copy"), db="PLATFORM_PROD_DB", schema="RAW")


def _oid(base: int, *parts) -> int:
    """A stable id for an object the demo names but never lists elsewhere."""
    return base + int(h(*parts)[:5], 16) % 90_000


def _ddl_object(g: Gen, r: dict, by_team: dict) -> dict:
    """OBJECT_MODIFIED_BY_DDL for one DDL statement: the operation and the object, no properties."""
    op, dom = DDL[r["query_type"]]
    wname = r["warehouse_name"]
    team = g.users.get(r["user_name"], {}).get("team") or (g.wh[wname]["team"] if wname else "PLATFORM")
    n = int(h(r["query_id"])[:6], 16)
    dev = [t for t in by_team.get(team, []) if t["db"].endswith("_DEV_DB") and t["type"] == "BASE TABLE"]
    prod = [t for t in by_team.get(team, []) if t["db"].endswith("_PROD_DB") and t["type"] == "BASE TABLE"]
    qt = r["query_type"]
    if qt == "CREATE_VIEW":
        try:
            node = json.loads(r["query_tag"] or "{}").get("node_id", "model.x.v_misc")
        except ValueError:
            node = "model.x.v_misc"
        model = node.split(".")[-1].upper()
        name = (f"{team}_DEV_DB.SCRATCH.CI_{model}" if wname == "WH_DBT_CI"
                else f"{r['database_name']}.{r['schema_name']}.{model}")
        oid = _oid(9_700_000, name)
    elif qt in ("CREATE_TABLE", "DROP"):
        name = f"{team}_DEV_DB.SCRATCH.TMP_{r['user_name'].split('_')[0]}_{n % 40:02d}"
        oid = _oid(9_600_000, name)
    elif qt in ("ALTER_TABLE_MODIFY_COLUMN", "RENAME_TABLE"):
        t = (dev or prod)[n % len(dev or prod)]
        name, oid = t["fqn"], t["id"]
    elif qt == "CREATE_SCHEMA":
        name = f"{team}_DEV_DB.SANDBOX_{n % 9}"
        oid = _oid(9_650_000, name)
    elif dom == "Task":
        ts = [t for t in g.b.cat["tasks"] if t["team"] == team] or g.b.cat["tasks"]
        t = ts[n % len(ts)]
        name, oid = f"{t['db']}.{t['schema']}.{t['name']}", t["id"]
        if qt == "CREATE_TASK":
            name = f"{team}_PROD_DB.STAGING.{team}_ADHOC_{n % 6}"
            oid = _oid(9_680_000, name)
    elif dom == "Stream":
        name = f"{team}_PROD_DB.STAGING.S_ADHOC_{n % 5}"
        oid = _oid(9_690_000, name)
    elif dom == "Role":
        name = f"{g.rng.choice(sorted(by_team))}_CONTRACTOR_{n % 4}"
        oid = _oid(9_660_000, name)
    elif dom == "Warehouse":
        w = sorted(g.wh.values(), key=lambda x: x["id"])[n % len(g.wh)]
        name, oid = w["name"], w["id"]
    else:                                             # grants and revokes on a team's mart table
        pool = [t for ts in by_team.values() for t in ts if t["schema"] == "MARTS" and t["type"] == "BASE TABLE"]
        t = sorted(pool, key=lambda x: x["id"])[n % len(pool)]
        name, oid = t["fqn"], t["id"]
    return {"objectDomain": dom, "objectName": name, "objectId": oid, "operationType": op, "properties": []}


def access(g: Gen) -> None:
    """ACCESS_HISTORY for the new statements: reads, column lineage of writes, stages, procedures and DDL."""
    by_team: dict = {}
    for t in g.tables:
        by_team.setdefault(t["team"], []).append(t)
    pii = {t["id"] for t in g.b.cat["tables"] if t["pii"]}
    dom = {"BASE TABLE": "Table", "VIEW": "View", "MATERIALIZED VIEW": "Materialized view"}
    # stages, and dynamic, external and Iceberg tables the other areas created, per team
    stages: dict = {}
    for s in g.w.rows.get(("account_usage", "STAGES"), []):
        if s.get("deleted") or not str(s["stage_catalog"]).endswith("_PROD_DB"):
            continue
        o = {"objectDomain": "Stage", "objectName": f"{s['stage_catalog']}.{s['stage_schema']}.{s['stage_name']}",
             "objectId": s["stage_id"], "stageKind": s["stage_type"]}
        if s.get("stage_url"):
            o["location"] = s["stage_url"]
        stages.setdefault(s["stage_catalog"][:-8], []).append(o)
    special: dict = {}
    for t in g.w.rows.get(("account_usage", "TABLES"), []):
        if t.get("deleted") or not str(t["table_catalog"]).endswith("_PROD_DB"):
            continue
        kind = ("Dynamic table" if t.get("is_dynamic") == "YES" else "Iceberg table" if t.get("is_iceberg") == "YES"
                else "External table" if t.get("table_type") == "EXTERNAL TABLE" else None)
        if kind:
            special.setdefault(t["table_catalog"][:-8], []).append(
                {"objectDomain": kind, "objectName": f"{t['table_catalog']}.{t['table_schema']}.{t['table_name']}",
                 "objectId": t["table_id"], "columns": [{"columnId": 1, "columnName": "ID"}]})
    procs = {team: {"objectDomain": "Procedure", "objectName": fqn, "objectId": 47_100 + i, "argumentSignature": "()",
                    "dataType": "VARCHAR"} for i, (team, fqn) in enumerate(sorted(PROCS.items()))}

    def cols(t):
        return ["ID", "AMOUNT"] + (["EMAIL"] if t["id"] in pii else [])

    def read(t):
        return {"objectDomain": dom.get(t["type"], "Table"), "objectName": t["fqn"], "objectId": t["id"],
                "columns": [{"columnId": i + 1, "columnName": c} for i, c in enumerate(cols(t))]}

    writes = ("INSERT", "MERGE", "COPY", "CREATE_TABLE_AS_SELECT", "UPDATE", "DELETE", "MULTI_TABLE_INSERT")
    lineage = ("INSERT", "MERGE", "CREATE_TABLE_AS_SELECT", "UPDATE", "MULTI_TABLE_INSERT")
    for r in g.rows:
        qt = r["query_type"]
        if r["execution_status"] != "SUCCESS":
            continue                                   # ACCESS_HISTORY records successful statements only
        ids = dict(query_id=r["query_id"], query_start_time=r["start_time"], user_name=r["user_name"],
                   policies_referenced=[], parent_query_id=r["_parent"], root_query_id=r["_parent"] or r["query_id"])
        if qt in DDL:
            g.b.au("ACCESS_HISTORY", direct_objects_accessed=[], base_objects_accessed=[], objects_modified=[],
                   object_modified_by_ddl=_ddl_object(g, r, by_team), **ids)
            continue
        if qt not in ("SELECT", "CALL", "UNLOAD") + writes or not r["warehouse_name"]:
            continue
        team = g.wh[r["warehouse_name"]]["team"]
        if qt == "CALL":
            p = procs.get(team) or procs["PLATFORM"]
            g.b.au("ACCESS_HISTORY", direct_objects_accessed=[p], base_objects_accessed=[p], objects_modified=[], **ids)
            continue
        if qt not in ("COPY", "UNLOAD") and g.rng.random() > 0.5:
            continue
        pool = [t for t in by_team.get(team, []) if not t["db"].endswith("_DEV_DB")]
        if not pool:
            continue
        ix = int(r["query_parameterized_hash"][:6], 16)
        srcs = [pool[ix % len(pool)]] + ([pool[(ix // 7) % len(pool)]] if ix % 3 == 0 else [])
        objs = [read(t) for t in srcs]
        if qt == "SELECT" and special.get(team) and ix % 5 == 0:
            objs.append(special[team][(ix // 5) % len(special[team])])
        tgt = [t for t in pool if t["type"] == "BASE TABLE" and t["schema"] != "RAW"] or \
              [t for t in pool if t["type"] == "BASE TABLE"]
        mod = []
        if qt == "COPY":
            st = stages.get(team) or [s for ss in stages.values() for s in ss if s["stageKind"] == "External Named"]
            objs = [st[ix % len(st)]] if st else []
            raw = [t for t in pool if t["type"] == "BASE TABLE" and t["schema"] == "RAW"] or tgt
            if raw:
                t = raw[(ix // 11) % len(raw)]
                mod = [{"objectDomain": "Table", "objectName": t["fqn"], "objectId": t["id"],
                        "columns": [{"columnId": i + 1, "columnName": c, "directSources": [], "baseSources": []}
                                    for i, c in enumerate(cols(t))]}]
        elif qt == "UNLOAD":
            st = stages.get(team) or [s for ss in stages.values() for s in ss]
            mod = [st[ix % len(st)]] if st else []
        elif qt in writes and tgt:
            t = tgt[(ix // 11) % len(tgt)]
            from_ = [s for s in srcs if s["id"] != t["id"]]
            out = []
            for i, c in enumerate(cols(t)):
                src = [{"objectDomain": dom.get(s["type"], "Table"), "objectName": s["fqn"], "objectId": s["id"],
                        "columnName": c} for s in from_ if qt in lineage and (c != "EMAIL" or s["id"] in pii)]
                if c == "EMAIL" and not src:
                    continue
                out.append({"columnId": i + 1, "columnName": c, "directSources": src, "baseSources": src})
            mod = [{"objectDomain": "Table", "objectName": t["fqn"], "objectId": t["id"], "columns": out}]
        g.b.au("ACCESS_HISTORY", direct_objects_accessed=objs, base_objects_accessed=objs, objects_modified=mod, **ids)


def pruning_views(g: Gen) -> None:
    """TABLE_PRUNING_HISTORY over the window and TABLE_QUERY_PRUNING_HISTORY for the scan shapes."""
    tables = sorted([t for t in g.tables if t["type"] == "BASE TABLE" and (t["bytes"] or 0) > 20 * GB],
                    key=lambda t: -t["bytes"])[:9]
    # table -> (baseline ratio, last-week ratio); a table new in the last 3 weeks has no baseline
    plans = [(0.92, 0.90), (0.85, 0.62), (0.80, 0.35), (0.95, 0.94), (0.70, 0.52), (0.88, 0.40), (0.60, 0.61),
             (0.90, 0.89), (0.75, 0.74)]
    for i, t in enumerate(tables):
        base, last = plans[i]
        new = i == 8
        for back in range(1, DAYS + 1):
            blk = (back - 1) // 7
            if new and blk > 2:
                continue
            ratio = (last if blk == 0 else base) + g.rng.uniform(-0.02, 0.02)
            total = int(g.rng.uniform(18_000, 30_000) * (1 if i % 3 else 2))
            st = dt.datetime.combine(g.b.back(back), dt.time(12))
            g.b.au("TABLE_PRUNING_HISTORY", start_time=st, end_time=st + dt.timedelta(hours=1), table_id=t["id"],
                   table_name=t["name"], schema_id=g.w.schema_id[(t["db"], t["schema"])], schema_name=t["schema"],
                   database_id=g.w.dbs[t["db"]], database_name=t["db"], num_scans=g.rng.randint(80, 400),
                   partitions_scanned=int(total * (1 - ratio)), partitions_pruned=int(total * ratio),
                   rows_scanned=int(total * (1 - ratio) * 4e5), rows_pruned=int(total * ratio * 4e5))
    # per table + warehouse + shape: rows matched over rows scanned, from the shapes that ran
    shapes: dict = {}
    for r in g.rows:
        if r["warehouse_name"] and r["partitions_total"] and r["query_type"] in ("SELECT", "DELETE", "MERGE",
                                                                                  "CREATE_TABLE_AS_SELECT", "INSERT"):
            key = (r["warehouse_id"], r["warehouse_name"], r["query_parameterized_hash"], r["start_time"].date())
            s = shapes.setdefault(key, [0, 0, 0, 0, 0, r])
            s[0] += 1
            s[1] += r["execution_time"]
            s[2] += r["partitions_scanned"] or 0
            s[3] += max(0, (r["partitions_total"] or 0) - (r["partitions_scanned"] or 0))
            s[4] += r["compilation_time"]
    matched = {"WH_MARKETING_ADHOC": 0.05, "WH_FINANCE_ADHOC": 0.4, "WH_SALES_ETL": 60.0, "WH_PRODUCT_ETL": 0.02,
               "WH_SALES_ADHOC": 12.0, "WH_DATA_SCIENCE_ETL": 30.0, "WH_OPS_BI": 3.0}
    for (wid, wname, ph, day), (n, ex, ps, pp, comp, r) in shapes.items():
        if day < g.b.back(DAYS) or wname not in matched:
            continue
        team = g.wh[wname]["team"]
        t = g.big_tables(team, 1)[0]
        rows = ps * 4e5
        st = dt.datetime.combine(day, dt.time(r["start_time"].hour))
        g.b.au("TABLE_QUERY_PRUNING_HISTORY", interval_start_time=st, interval_end_time=st + dt.timedelta(hours=1),
               table_id=t["id"], table_name=t["name"], schema_id=g.w.schema_id[(t["db"], t["schema"])],
               schema_name=t["schema"], database_id=g.w.dbs[t["db"]], database_name=t["db"], warehouse_id=wid,
               warehouse_name=wname, query_hash=r["query_hash"], query_parameterized_hash=ph, num_queries=n,
               aggregate_query_elapsed_time=ex + comp, aggregate_query_compilation_time=comp,
               aggregate_query_execution_time=ex, partitions_scanned=ps, partitions_pruned=pp,
               rows_scanned=int(rows), rows_pruned=int(pp * 4e5),
               rows_matched=int(rows * matched[wname] / 100 * g.rng.uniform(0.8, 1.2)))


def aggregate_history(g: Gen) -> None:
    """High-frequency statement shapes: per-interval call counts and latency percentiles."""
    shapes = [  # wh, team, qtype, calls per interval, p99 ms, avg ms, queued share, throttled per interval, errors
        ("WH_STREAMLIT_APPS", "PRODUCT", "SELECT", 300, 900, 120, 0.0, 0, None),
        ("WH_REVERSE_ETL", "MARKETING", "SELECT", 300, 7500, 900, 0.02, 0, [{"code": "000630", "message": "timeout", "count": 2}]),
        ("WH_SALES_BI", "SALES", "SELECT", 260, 45000, 4000, 0.35, 0, None),
        ("WH_PRODUCT_BI", "PRODUCT", "SELECT", 400, 600, 40, 0.0, 9, None),
        ("WH_PLATFORM_BI", "PLATFORM", "SELECT", 250, 1500, 200, 0.0, 1, None),
        ("WH_PLATFORM_ADHOC", "PLATFORM", "SHOW", 280, 400, 60, 0.0, 0, [{"code": "002003", "message": "x", "count": 4}]),
        ("WH_FINANCE_BI", "FINANCE", "SELECT", 120, 3000, 300, 0.12, 0, None),
    ]
    for wname, team, qtype, calls, p99, avg, qshare, thr, errs in shapes:
        w = g.wh[wname]
        ph = h("hf", wname)
        daily = wname in ("WH_PLATFORM_ADHOC", "WH_REVERSE_ETL")     # the rest serve office-hours dashboards
        for back in range(1, QDAYS + 1):
            if not daily and g.b.back(back).weekday() >= 5:
                continue
            for hr in (9, 12, 15):
                n = int(calls * g.rng.uniform(0.85, 1.15) * g.share(back))
                el = n * avg
                st = dt.datetime.combine(g.b.back(back), dt.time(hr))
                g.b.au("AGGREGATE_QUERY_HISTORY", calls=n, interval_start_time=st,
                       interval_end_time=st + dt.timedelta(minutes=1), query_parameterized_hash=ph,
                       query_text="select ... where id = ?", database_id=g.w.dbs[f"{team}_PROD_DB"],
                       database_name=f"{team}_PROD_DB", schema_id=g.w.schema_id[(f"{team}_PROD_DB", "MARTS")],
                       schema_name="MARTS", query_type=qtype, user_name=g.svc(team, "REPORTING"),
                       role_name=f"{team}_READ", role_type="ROLE", warehouse_id=w["id"], warehouse_name=wname,
                       warehouse_size=g.w.size_at(w, st), warehouse_type=w["type"], is_client_generated_statement=False,
                       release_version="9.30.1", errors=errs,
                       total_elapsed_time={"sum": el, "avg": avg, "p99": int(p99 * g.rng.uniform(0.9, 1.1))},
                       queued_overload_time={"sum": el * qshare}, credits_used_cloud_services={"sum": n * 0.00001},
                       hybrid_table_requests_throttled_count=thr if thr else None)


def add(b) -> None:
    g = Gen(b)
    long_runs(g)                                      # first: multi-hour runs need whole free hours
    dashboards(g)
    dbt_projects(g)
    dbt_ci(g)
    generated_sql(g)
    spills(g)
    full_scans(g)
    large_results(g)
    locks(g)
    failures(g)
    metadata_poller(g)
    other_types(g)
    access(g)
    pruning_views(g)
    aggregate_history(g)
    demo_ai_perf.add_shapes(g)                        # own random stream: shapes slower in the last week
    g.flush_sessions()                                # last: each session signs in before its first statement
