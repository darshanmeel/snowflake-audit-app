"""Demo pipelines: task graphs, serverless task credits, Snowpipe and COPY, streams, dynamic tables and alerts.

Tasks and pipes come from demo_entities.catalog(); a few extra tasks, pipes, streams, dynamic tables and alerts
live here, with ids in their own ranges. A task with a root in the catalog is a child: it has no schedule of its
own and runs when its root's run succeeds. Warehouse task statements and dynamic table refreshes go into
QUERY_HISTORY, ACCESS_HISTORY (what they read and write), and into QUERY_ATTRIBUTION_HISTORY only up to the idle
credits the warehouse already billed in that hour, so attribution never exceeds metering. Every draw comes from b.rng.
"""
from __future__ import annotations

import bisect
import datetime as dt
import hashlib
from collections import defaultdict

from tests.fake_snowflake import demo_pipe_fit
from tests.fake_snowflake.data import RATE

DAYS = 185                 # a 90-day window and the one before it
DETAIL_DAYS = 95           # per-file, per-event and per-read rows: the 90-day window and a margin
MIN = dt.timedelta(minutes=1)
SEC = dt.timedelta(seconds=1)

# Per task: base run seconds, serverless credits per hour of run, share of no-op runs, and story overrides.
# broken = (from days ago, to days ago or 0, fail rate, ERRORS index): a fault that starts and may get fixed.
TASK_PROFILE = {
    "FINANCE_LOAD_01": dict(secs=150, noop=0.1, err_int="ERR_NOTIFY_FINANCE", stream="FIN_ORDERS",
                            broken=(9, 0, 0.45, 2)),
    "FINANCE_LOAD_02": dict(secs=70, sl_rate=2.0, schedule="10 MINUTE"),
    "FINANCE_LOAD_04": dict(secs=420),
    "FINANCE_LOAD_05": dict(secs=200, suspended_days=3, reason="USER_SUSPENDED"),
    "MARKETING_LOAD_01": dict(secs=240, schedule="60 MINUTE", err_int="ERR_NOTIFY_EMAIL", sl_rate=1.0),
    "MARKETING_LOAD_02": dict(secs=900, changed_days=24, manual_runs=(33, 17, 5, 2)),
    "MARKETING_LOAD_04": dict(secs=120, noop=0.55),
    "SALES_LOAD_01": dict(secs=600, suspended_days=40, reason="USER_SUSPENDED", stream="SALES_LEADS"),
    "SALES_LOAD_02": dict(secs=1700, sl_rate=1.0, changed_days=21),
    "PLATFORM_LOAD_01": dict(secs=1100, streak=4, changed_days=22, retry=True, manual_retry_days=(1,)),
    "PLATFORM_LOAD_02": dict(secs=500, forced_fails=(6, 19), retry=True, manual_retry_days=(6,)),
    "PLATFORM_LOAD_05": dict(secs=300, sl_rate=1.0),
    "DATA_SCIENCE_LOAD_01": dict(secs=200, schedule="60 MINUTE", suspended_days=18, reason="SUSPENDED_DUE_TO_ERRORS", fail_before=10),
    "DATA_SCIENCE_LOAD_02": dict(secs=90, noop=0.95, changed_days=20),
    "DATA_SCIENCE_LOAD_04": dict(secs=150, suspended_days=18, reason="USER_SUSPENDED"),
    "PRODUCT_LOAD_01": dict(secs=25, schedule="30 MINUTE", noop=0.6, overlap="ALLOW_ALL_OVERLAP", err_int="ERR_NOTIFY_EMAIL",
                            stream="PRODUCT_EVENTS", cond_skip=0.3),
    "PRODUCT_LOAD_02": dict(secs=150, err_int="ERR_NOTIFY_EMAIL"),
    "PRODUCT_LOAD_03": dict(secs=40, noop=0.2, stream="PRODUCT_EVENTS", cond_skip=0.7),
    "RISK_LOAD_01": dict(secs=1300, schedule="30 MINUTE", sl_rate=0.5, run_as_gone=True),
    "RISK_LOAD_02": dict(secs=30, schedule="15 MINUTE", suspended_days=25, reason="USER_SUSPENDED", stream="RISK_TRADES"),
    "RISK_LOAD_03": dict(secs=120, suspended_days=10, reason="USER_SUSPENDED", stream="RISK_POSITIONS"),
    "RISK_LOAD_04": dict(stream="RISK_POSITIONS"),
    "RISK_LOAD_05": dict(broken=(40, 12, 0.7, 3)),           # lost a grant, fixed twelve days ago
    "OPS_LOAD_02": dict(secs=20, noop=0.7, stream="OPS_TICKETS"),
    "OPS_LOAD_01": dict(secs=300, finalizer=True, err_int=None),
    "OPS_LOAD_04": dict(broken=(70, 63, 0.3, 4)),             # a bad week of duplicate keys
    "PRODUCT_EVENTS_TRIGGERED": dict(secs=35, stream="PRODUCT_EVENTS", sl_rate=1.0),
    "OPS_REPORT_REFRESH": dict(secs=12, noop=0.8),            # tiny, frequent, keeps a warehouse awake
}
DEFAULT_SECS = {5: 40, 10: 60, 15: 90, 30: 120, 60: 180, 1440: 600}

# Extra tasks: (id, name, team, schema, warehouse, schedule, owner, state, story)
EXTRA_TASKS = [
    (70101, "FINANCE_MONTH_CLOSE", "FINANCE", "MARTS", "WH_FINANCE_ETL", "USING CRON 0 6 1 * * UTC", "FINANCE_ADMIN",
     "suspended", "never_ran"),
    (70102, "MARKETING_LEGACY_SYNC", "MARKETING", "STAGING", None, "USING CRON 30 3 * * * UTC", "LEGACY_ETL_ROLE",
     "started", "orphan"),
    (70103, "MARKETING_LEGACY_EXPORT", "MARKETING", "MARTS", None, "USING CRON 45 3 * * * UTC", "LEGACY_ETL_ROLE",
     "started", "orphan"),
    (70104, "OPS_LOAD_FINALIZE", "OPS", "STAGING", None, None, "OPS_ADMIN", "started", "finalizer"),
    (70105, "PLATFORM_AUDIT_SNAPSHOT", "PLATFORM", "MARTS", None, "USING CRON 0 5 * * * UTC", "ACCOUNTADMIN",
     "started", "admin"),
    # the rest of what the dropped contractor role owned: nobody can manage these any more
    (70106, "MARKETING_LEGACY_DEDUP", "MARKETING", "STAGING", None, "USING CRON 15 4 * * * UTC", "LEGACY_ETL_ROLE",
     "started", "orphan"),
    (70107, "MARKETING_LEGACY_BACKFILL", "MARKETING", "STAGING", "WH_MARKETING_ETL", "USING CRON 0 5 * * * UTC",
     "LEGACY_ETL_ROLE", "suspended", "orphan"),
    (70108, "SALES_CONTRACTOR_EXPORT", "SALES", "MARTS", None, "USING CRON 0 6 * * * UTC", "LEGACY_ETL_ROLE",
     "suspended", "orphan"),
    # a triggered task: no schedule, runs when its stream has data
    (70109, "PRODUCT_EVENTS_TRIGGERED", "PRODUCT", "STAGING", None, None, "PRODUCT_ADMIN", "started", "triggered"),
    # a short report refresh every 10 minutes on a warehouse that does little else
    (70110, "OPS_REPORT_REFRESH", "OPS", "MARTS", "WH_LEGACY_REPORTS", "10 MINUTE", "OPS_ADMIN", "started", "short"),
]
LEGACY_ROLE = (61901, "LEGACY_ETL_ROLE", 11)              # id, name, dropped days ago

# Snowflake's message formats; {src}, {tgt}, {val} and {n} are filled per task so messages quote real names.
ERRORS = [("000630", "Statement reached its statement or warehouse timeout of 3,600 second(s) and was canceled."),
          ("002003", "SQL compilation error: Object '{src}' does not exist or not authorized."),
          ("100038", "Numeric value '{val}' is not recognized"),
          ("003001", "SQL access control error: Insufficient privileges to operate on table '{tgt}'"),
          ("100090", "Duplicate row detected during DML action Row Values: [{n}, \"{val}\"]"),
          ("000604", "SQL execution canceled")]
CANCELED = 5
BAD_VALUES = ["N/A", "", "1,234.50", "-", "null"]
TEAM_ERROR = {"FINANCE": 4, "MARKETING": 1, "SALES": 0, "PLATFORM": 1, "DATA_SCIENCE": 0, "PRODUCT": 4, "RISK": 0,
              "OPS": 1}
BASE_FAIL = {0.6: 0.03, 0.2: 0.03, 0.05: 0.02}             # the catalog's rates, kept to a few percent
OVERLAP_MSG = "Task run skipped: the previous run of the task was still executing."
COND_MSG = "Conditional expression for task evaluated to false."


def _interval_minutes(schedule: str | None) -> int | None:
    if not schedule:
        return None
    if schedule.endswith("MINUTE"):
        return int(schedule.split()[0])
    return 60 if schedule.split()[3] == "*" else 1440       # USING CRON m h ...: hourly or daily


def _cron_hour_minute(schedule: str) -> tuple[int, int]:
    parts = schedule.split()
    return (int(parts[3]) if parts[3] != "*" else 0), int(parts[2])


def _h(*parts) -> str:
    return hashlib.md5("|".join(map(str, parts)).encode()).hexdigest()[:16]


def _obj(fqn: str, oid: int, domain: str = "Table") -> dict:
    return {"objectDomain": domain, "objectName": fqn, "objectId": oid,
            "columns": [{"columnId": 1, "columnName": "ID"}, {"columnId": 2, "columnName": "AMOUNT"}]}


class _Ctx:
    """Lookups shared by the sections: ids from the catalog and the base rows, a query id counter, headroom."""

    def __init__(self, b):
        self.b, self.w, self.rng, self.cat = b, b.w, b.rng, b.cat
        self.wh = {w["name"]: w for w in self.cat["warehouses"]}
        self.db_id = {d["name"]: d["id"] for d in self.cat["databases"]}
        self.schema_id = {(s["db"], s["name"]): s["id"] for s in self.cat["schemas"]}
        self.tables = defaultdict(list)
        for t in self.cat["tables"]:
            if t["type"] == "BASE TABLE":
                self.tables[(t["db"], t["schema"])].append(t)
        self.table_rows = {r["table_id"]: r for r in self.w.rows[("account_usage", "TABLES")]}
        self.users = {r["name"]: r for r in self.w.rows[("account_usage", "USERS")]}
        self.n = 0
        self.headroom: dict[tuple[int, dt.datetime], float] = {}
        demo_ids = {w["id"] for w in self.cat["warehouses"]}
        for r in self.w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]:
            if r["warehouse_id"] in demo_ids and r.get("credits_attributed_compute_queries") is not None:
                self.headroom[(r["warehouse_id"], r["start_time"])] = max(
                    0.0, r["credits_used_compute"] - r["credits_attributed_compute_queries"])
        self.sched_start = b.ts(DAYS)
        self.detail_start = b.ts(DETAIL_DAYS)

    def qid(self, kind: str) -> str:
        self.n += 1
        return f"01p{kind}-{self.n:07d}"

    def old_tables(self, db: str, schema: str) -> list[dict]:
        """Live base tables of a schema that existed before the demo's history starts (all of them if none)."""
        tbls = self.tables[(db, schema)]
        old = []
        for t in tbls:
            r = self.table_rows.get(t["id"])
            if r and r.get("deleted") is None and r["created"] <= self.sched_start:
                old.append(t)
        return old or tbls

    def stmt(self, qid, wh_name, start, secs, qtype, role, db, schema, ok=True, err=None, rows_changed=0,
             user="SYSTEM", qh=True, hkey=None, sess_key=0):
        """A system statement on a warehouse: QUERY_HISTORY, and attribution up to that hour's billed idle."""
        w = self.wh[wh_name]
        ms = int(secs * 1000)
        end = start + dt.timedelta(milliseconds=ms)
        qhash = f"hp{_h(hkey, qtype)}" if hkey else f"hp{qtype[:2].lower()}{len(db)}"
        if qh:
            scanned = int(secs * 4e7)
            dml = qtype in ("INSERT", "MERGE", "DELETE", "UPDATE")
            self.b.au("QUERY_HISTORY", query_id=qid, query_text=None, database_id=self.db_id.get(db), database_name=db,
                      schema_id=self.schema_id.get((db, schema)), schema_name=schema, query_type=qtype,
                      session_id=9_100_000_000_000 + sess_key * 100_000 + start.date().toordinal() % 100_000,
                      user_name=user, role_name=role, warehouse_id=w["id"], warehouse_name=wh_name,
                      warehouse_size=self.w.size_at(w, start), warehouse_type=w["type"], cluster_number=1,
                      execution_status="SUCCESS" if ok else "FAIL", error_code=int(err[0]) if err else None,
                      error_message=err[1] if err else None, start_time=start, end_time=end,
                      total_elapsed_time=ms + 150, compilation_time=150, execution_time=ms,
                      queued_provisioning_time=0, queued_repair_time=0, queued_overload_time=0,
                      transaction_blocked_time=0, child_queries_wait_time=0, query_retry_time=0,
                      fault_handling_time=0, bytes_scanned=scanned,
                      percentage_scanned_from_cache=round(self.rng.uniform(0, 0.6), 3),
                      bytes_written=int(rows_changed * 120), bytes_written_to_result=16 if dml else 0,
                      bytes_read_from_result=0, rows_produced=rows_changed if dml else 0,
                      rows_inserted=rows_changed if qtype in ("INSERT", "MERGE") else 0,
                      rows_updated=0, rows_deleted=rows_changed if qtype == "DELETE" else 0, rows_unloaded=0,
                      bytes_deleted=0, partitions_scanned=max(1, int(secs * 3)), partitions_total=max(4, int(secs * 10)),
                      bytes_spilled_to_local_storage=0, bytes_spilled_to_remote_storage=0,
                      bytes_sent_over_the_network=int(scanned * self.rng.uniform(0.002, 0.02)),
                      credits_used_cloud_services=0.00015, query_load_percent=self.rng.randint(20, 100),
                      query_acceleration_bytes_scanned=0, query_acceleration_partitions_scanned=0,
                      query_acceleration_upper_limit_scale_factor=0, query_hash=qhash, query_hash_version=2,
                      query_parameterized_hash=qhash, query_parameterized_hash_version=1,
                      transaction_id=80_000_000 + self.n, role_type="ROLE", user_type="SERVICE",
                      is_client_generated_statement=False, user_database_id=str(self.db_id.get(db)),
                      user_database_name=db, user_schema_id=str(self.schema_id.get((db, schema))),
                      user_schema_name=schema)
        hour = start.replace(minute=0, second=0, microsecond=0)
        room = self.headroom.get((w["id"], hour), 0.0)
        credits = min(RATE[self.w.size_at(w, start)] * secs / 3600, room)
        if credits >= 0.0005:                      # attribution leaves out tiny and unmetered statements
            self.headroom[(w["id"], hour)] = room - credits
            self.b.au("QUERY_ATTRIBUTION_HISTORY", query_id=qid, parent_query_id=None, root_query_id=qid,
                      warehouse_id=w["id"], warehouse_name=wh_name, query_hash=qhash,
                      query_parameterized_hash=qhash, query_tag=None, user_name=user,
                      start_time=start, end_time=end, credits_attributed_compute=credits,
                      credits_used_query_acceleration=None)
        return end

    def access(self, qid, start, direct, base, target=None, user="SYSTEM"):
        """ACCESS_HISTORY for one statement: what it read and, with column lineage, the table it wrote."""
        mod = []
        if target:
            src = lambda objs: [{"objectDomain": o["objectDomain"], "objectName": o["objectName"],
                                 "objectId": o["objectId"], "columnName": "ID"} for o in objs]
            mod = [{"objectDomain": "Table", "objectName": target[0], "objectId": target[1],
                    "columns": [{"columnId": 1, "columnName": "ID", "directSources": src(direct), "baseSources": src(base)}]}]
        self.b.au("ACCESS_HISTORY", query_id=qid, query_start_time=start, user_name=user,
                  direct_objects_accessed=direct, base_objects_accessed=base, objects_modified=mod,
                  policies_referenced=[], parent_query_id=None, root_query_id=qid)


# ---------------------------------------------------------------------------------------------------------------------
# Streams: sources first, as tasks read them
# ---------------------------------------------------------------------------------------------------------------------
STREAMS = [  # stream suffix, team, days to stale from the as-of date (None = stale), mode, consuming task
    ("FIN_ORDERS", "FINANCE", 11.0, "DEFAULT", "FINANCE_LOAD_01"),
    ("SALES_LEADS", "SALES", 9.0, "DEFAULT", "SALES_LOAD_01"),
    ("PRODUCT_EVENTS", "PRODUCT", 13.0, "APPEND_ONLY", "PRODUCT_LOAD_01"),
    ("OPS_TICKETS", "OPS", 4.0, "DEFAULT", "OPS_LOAD_02"),
    ("RISK_TRADES", "RISK", None, "DEFAULT", "RISK_LOAD_02"),
    ("DS_LABELS", "DATA_SCIENCE", 1.5, "DEFAULT", None),
    ("MKT_CLICKS", "MARKETING", 12.0, "APPEND_ONLY", None),
    ("PLATFORM_AUDIT", "PLATFORM", 10.0, "DEFAULT", None),
    ("RISK_POSITIONS", "RISK", 8.0, "DEFAULT", "RISK_LOAD_04"),   # one of its two consumers is suspended
]
# Streams on other sources: an external table (INSERT_ONLY) and a view over two tables.
OTHER_STREAMS = [  # suffix, team, days to stale, mode, source type
    ("PLATFORM_LANDING", "PLATFORM", 20.0, "INSERT_ONLY", "External Table"),
    ("FIN_LEDGER_VIEW", "FINANCE", 7.0, "DEFAULT", "View"),
]


def _stream_sources(c: _Ctx) -> dict[str, dict]:
    """Per stream suffix: its fqn, id and source table (an old RAW table of the team)."""
    out = {}
    for i, (suffix, team, *_rest) in enumerate(STREAMS):
        db = f"{team}_PROD_DB"
        raw = c.old_tables(db, "RAW")
        src = raw[i % len(raw)] if raw else None
        out[suffix] = dict(i=i, fqn=f"{db}.STAGING.S_{suffix}", id=90000 + i, db=db, team=team,
                           src_fqn=f"{db}.RAW.{src['name']}" if src else f"{db}.RAW.EVENTS",
                           src_id=src["id"] if src else 0)
    return out


def streams(c: _Ctx, ssrc: dict[str, dict]) -> None:
    """SHOW STREAMS; the consuming tasks' reads are written with each task run."""
    b, rng = c.b, c.rng
    base = b.ts(0)                                  # stale_after counts from the as-of date, never the clock
    for suffix, team, days, mode, consumer in STREAMS:
        s = ssrc[suffix]
        stale_after = base + dt.timedelta(days=days) if days is not None else base - dt.timedelta(days=6)
        b.show("streams", created_on=b.ts(150 + s["i"] * 7, 9), name=f"S_{suffix}", database_name=s["db"],
               schema_name="STAGING", owner=f"{team}_ADMIN", comment="", table_name=s["src_fqn"], source_type="Table",
               base_tables=s["src_fqn"], type="DELTA", stale="true" if days is None else "false",
               stale_after=stale_after, mode=mode, invalid_reason="N/A")
        if suffix == "PLATFORM_AUDIT":
            for k in (2, 5, 9):                          # read by hand now and then: fresh, not idle
                c.access(c.qid("s"), b.ts(k, 10, rng.randint(0, 59)), [_obj(s["fqn"], s["id"], "Stream")], [],
                         user="SVC_PLATFORM_REPORTING")
    for j, (suffix, team, days, mode, stype) in enumerate(OTHER_STREAMS):
        db = f"{team}_PROD_DB"
        fqn = f"{db}.STAGING.S_{suffix}"
        if stype == "View":
            tbls = c.old_tables(db, "MARTS")[:2] or c.old_tables(db, "STAGING")[:2]
            src = f"{db}.MARTS.V_LEDGER_OPEN"
            bases = ", ".join(f"{t['db']}.{t['schema']}.{t['name']}" for t in tbls)
        else:
            src = bases = f"{db}.RAW.EXT_LANDING_FILES"
        b.show("streams", created_on=b.ts(70 + j * 20, 9), name=f"S_{suffix}", database_name=db, schema_name="STAGING",
               owner=f"{team}_ADMIN", comment="", table_name=src, source_type=stype, base_tables=bases, type="DELTA",
               stale="false", stale_after=b.ts(0) + dt.timedelta(days=days), mode=mode, invalid_reason="N/A")
        if stype == "View":
            for k in (1, 3, 6):
                c.access(c.qid("s"), b.ts(k, 7, rng.randint(0, 59)), [_obj(fqn, 90100 + j, "Stream")], [],
                         user=f"SVC_{team}_REPORTING")


# ---------------------------------------------------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------------------------------------------------
def _task_list(c: _Ctx) -> list[dict]:
    """Catalog tasks plus the extras, with the profile above; children lose their own schedule."""
    out = []
    for t in c.cat["tasks"]:
        p = dict(TASK_PROFILE.get(t["name"], {}))
        x = dict(t)
        x["schedule"] = None if t["root"] else p.get("schedule", t["schedule"])
        x["fail_rate"] = BASE_FAIL.get(t["fail_rate"], t["fail_rate"])
        x.update(story=None, p=p)
        out.append(x)
    for tid, name, team, schema, wh, sched, owner, state, story in EXTRA_TASKS:
        p = dict(secs=240 if story != "finalizer" else 45, sl_rate=1.0)
        p.update(TASK_PROFILE.get(name, {}))
        out.append(dict(id=tid, name=name, db=f"{team}_PROD_DB", schema=schema, team=team, warehouse=wh, schedule=sched,
                        root="OPS_PROD_DB.STAGING.OPS_LOAD_01" if story == "finalizer" else None,
                        fail_rate=0.01 if story == "short" else 0.0, slowdown=1.0, suspended=state == "suspended",
                        owner=owner, story=story, p=p))
    for x in out:
        x["fqn"] = f"{x['db']}.{x['schema']}.{x['name']}"
        p = x["p"]
        if x["suspended"] and "suspended_days" not in p and x["story"] != "never_ran":
            p.update(suspended_days=12, reason="USER_SUSPENDED")
    by_fqn = {x["fqn"]: x for x in out}
    for x in out:
        x["root_task"] = by_fqn.get(x["root"]) if x["root"] else None
    return out


def _task_io(c: _Ctx, x: dict, ssrc: dict[str, dict]) -> None:
    """What a task reads (its stream or a RAW table) and the table it writes in its own schema."""
    pool = c.old_tables(x["db"], x["schema"]) or c.old_tables(x["db"], "STAGING")
    tgt = pool[x["id"] % len(pool)] if pool else None
    x["target"] = (f"{x['db']}.{x['schema']}.{tgt['name']}", tgt["id"]) if tgt else None
    stream = x["p"].get("stream")
    if stream:
        s = ssrc[stream]
        x["direct"] = [_obj(s["fqn"], s["id"], "Stream")]
        x["base"] = [_obj(s["src_fqn"], s["src_id"])]
    else:
        raw = c.old_tables(x["db"], "RAW")
        src = raw[(x["id"] // 3) % len(raw)] if raw else None
        objs = [_obj(f"{x['db']}.RAW.{src['name']}", src["id"])] if src else []
        x["direct"], x["base"] = objs, objs


def _error(c: _Ctx, x: dict, idx: int) -> tuple[str, str]:
    code, msg = ERRORS[idx]
    src = x["base"][0]["objectName"] if x.get("base") else f"{x['db']}.RAW.SRC"
    tgt = x["target"][0].split(".")[-1] if x.get("target") else x["name"]
    return code, msg.format(src=src.replace("RAW.", "RAW_V2.") if idx == 1 else src, tgt=tgt,
                            val=c.rng.choice(BAD_VALUES), n=c.rng.randint(1000, 999999))


def tasks(c: _Ctx, ssrc: dict[str, dict]) -> list[dict]:
    b, rng = c.b, c.rng
    tl = _task_list(c)
    for x in tl:
        _task_io(c, x, ssrc)
    roots = [x for x in tl if x["root_task"] is None and x["story"] not in ("never_ran", "triggered")]
    triggered = [x for x in tl if x["story"] == "triggered"]
    children = defaultdict(list)
    for x in tl:
        if x["root_task"] is not None and x["story"] != "finalizer":
            children[x["root_task"]["fqn"]].append(x)
    finalizer = next(x for x in tl if x["story"] == "finalizer")
    sl_hour: dict[tuple[int, dt.datetime], float] = defaultdict(float)
    as_of = c.w.now.replace(hour=0)                  # runs stop at the start of the as-of day

    def susp_at(x):
        k = x["p"].get("suspended_days")
        return b.ts(k, 8) if k is not None else None

    def graph_version(root, when):
        k = root["p"].get("changed_days")
        return 2 if k and when >= b.ts(k, 10) else 1

    def secs_for(x, when):
        p = x["p"]
        iv = _interval_minutes(x["schedule"] or (x["root_task"] or {}).get("schedule")) or 1440
        base = p.get("secs") or DEFAULT_SECS.get(iv, 180)
        s = base * rng.lognormvariate(0, 0.18)
        if x["slowdown"] > 1 and (as_of - when).days < 26:
            s *= x["slowdown"]
        return s

    def run(x, when, meta, force=None):
        """One run of one task; returns (state, end time, error)."""
        p = x["p"]
        cond = None
        if p.get("stream"):
            cond = f"SYSTEM$STREAM_HAS_DATA('STAGING.S_{p['stream']}')"
        if cond and rng.random() < p.get("cond_skip", 0.0):
            _history(c, x, when, "SKIPPED", None, None, None, meta, cond, COND_MSG)
            return "SKIPPED", when, None
        secs = secs_for(x, when)
        rate, err_idx = x["fail_rate"], p.get("err", TEAM_ERROR[x["team"]])
        br = p.get("broken")
        in_break = bool(br) and b.ts(br[0]) <= when < (b.ts(br[1]) if br[1] else as_of + dt.timedelta(days=1))
        if in_break:
            rate, err_idx = br[2], br[3]
        r = rng.random()
        state = force or ("FAILED" if r < rate else ("CANCELLED" if r > 0.997 else "SUCCEEDED"))
        err = None
        if state == "FAILED":
            if not in_break and rng.random() < 0.25:
                err_idx = rng.choice((0, 1, 4))
            err = _error(c, x, err_idx)
            secs *= rng.uniform(0.1, 0.6)
        elif state == "CANCELLED":
            err = _error(c, x, CANCELED)
            secs *= rng.uniform(0.05, 0.3)
        qid = c.qid("t")
        start = when + SEC
        end = start + dt.timedelta(seconds=secs)
        if x["warehouse"]:
            noop = state == "SUCCEEDED" and rng.random() < p.get("noop", 0.0)
            rows = 0 if noop else int(rng.uniform(2e3, 4e5))
            c.stmt(qid, x["warehouse"], start, secs, "MERGE" if not p.get("stream") else "INSERT", x["owner"],
                   x["db"], x["schema"], ok=state == "SUCCEEDED", err=err, rows_changed=rows, hkey=x["fqn"],
                   sess_key=x["id"])
            if state == "SUCCEEDED" and when >= c.detail_start:
                c.access(qid, start, x["direct"], x["base"], None if noop else x["target"])
        else:
            hr = start.replace(minute=0, second=0, microsecond=0)
            sl_hour[(x["id"], hr)] += secs / 3600 * p.get("sl_rate", 1.0) * 0.9
            if state == "SUCCEEDED" and when >= c.detail_start:      # serverless runs read their stream too
                c.access(qid, start, x["direct"], x["base"], x["target"])
        _history(c, x, when, state, start, end, qid, meta, cond, err)
        return state, end, err

    def graph(root, when, meta, force=None):
        """A root run, its children when it succeeds, and the finalizer."""
        state, end, err = run(root, when, meta, force)
        g_end, first_err, g_state = end, ((root["name"], err) if state == "FAILED" else None), state
        if state == "SUCCEEDED":
            for ch in children[root["fqn"]]:
                s_at = susp_at(ch)
                if s_at and when >= s_at:
                    continue
                cs, ce, cerr = run(ch, end, meta)
                g_end = max(g_end, ce)
                if cs in ("FAILED", "CANCELLED") and g_state == "SUCCEEDED":
                    g_state, first_err = cs, (ch["name"], cerr)
        if root["fqn"] == finalizer["root"]:
            run(finalizer, g_end, meta)
        return state, end, g_end, g_state, first_err

    def meta_for(root, when, sched_from="SCHEDULE", attempt=1, run_id=None):
        run_id = run_id or int(when.replace(tzinfo=dt.timezone.utc).timestamp() * 1000)
        return dict(run_id=run_id, graph_v=graph_version(root, when), sched_from=sched_from, attempt=attempt,
                    group=f"gp{root['id']}-{run_id}")

    graph_rows = []
    for root in roots:
        p = root["p"]
        sched = root["schedule"]
        iv = _interval_minutes(sched)
        if sched.startswith("USING CRON"):
            hh, mm = _cron_hour_minute(sched)
            first = c.sched_start.replace(hour=hh if iv == 1440 else 0, minute=mm)
        else:
            first = c.sched_start + dt.timedelta(minutes=rng.randint(0, iv - 1))
        s_at = susp_at(root)
        stop = min(as_of, s_at or as_of)
        prev_end = None
        when = first
        streak = p.get("streak", 0)
        fail_before = p.get("fail_before", 0)
        forced = p.get("forced_fails", ())
        allow_overlap = p.get("overlap") == "ALLOW_ALL_OVERLAP"
        while when < stop:
            meta = meta_for(root, when)
            nxt = when + dt.timedelta(minutes=iv)
            nxt = None if s_at and nxt >= s_at else nxt   # the last run before a suspend has no next one
            if prev_end and when < prev_end and not allow_overlap:
                _history(c, root, when, "SKIPPED", None, None, None, meta, None, OVERLAP_MSG)
                when += dt.timedelta(minutes=iv)
                continue
            back = (as_of - when).days
            force = None
            in_streak = bool(streak) and when >= stop - dt.timedelta(days=streak)
            if in_streak:
                force = "FAILED"                          # failing every run lately
            if fail_before and when >= stop - dt.timedelta(minutes=iv * fail_before):
                force = "FAILED"                          # the failures that got it auto-suspended
            if back in forced:
                force = "FAILED"
            state, end, g_end, g_state, first_err = graph(root, when, meta, force)
            prev_end = end if state != "SKIPPED" else prev_end
            if state != "SKIPPED":
                graph_rows.append((root, when, g_end, g_state, first_err, meta, nxt))
            # retries: same run id and graph run group, a higher attempt number
            manual = p.get("manual_retry_days", ())
            attempt, t = 1, g_end
            while state == "FAILED" and p.get("retry") and attempt < 3:
                attempt += 1
                if attempt == 2:
                    sched_from, rt = "AUTOMATIC RETRY", t + 10 * MIN
                    f = "FAILED" if in_streak or back in manual else ("SUCCEEDED" if force else None)
                elif back in manual:
                    sched_from, rt = "MANUAL RETRY", t + dt.timedelta(hours=3)
                    f = "FAILED" if in_streak else "SUCCEEDED"
                else:
                    break
                rmeta = dict(meta, sched_from=sched_from, attempt=attempt)
                state, end, g_end, g_state, first_err = graph(root, rt, rmeta, f)
                prev_end = max(prev_end or end, end)
                graph_rows.append((root, rt, g_end, g_state, first_err, rmeta, nxt))
                t = g_end
            when += dt.timedelta(minutes=iv)
        # manual runs by an admin: EXECUTE TASK outside the schedule
        for k in p.get("manual_runs", ()):
            t = b.ts(k, 14, rng.randint(0, 59))
            if t >= stop:
                continue
            meta = meta_for(root, t, "EXECUTE_TASK")
            slots = -(-(t - first) // dt.timedelta(minutes=iv))
            nxt = first + slots * dt.timedelta(minutes=iv)
            state, end, g_end, g_state, first_err = graph(root, t, meta)
            if state != "SKIPPED":
                graph_rows.append((root, t, g_end, g_state, first_err, meta, nxt))

    for root in triggered:                            # runs whenever its stream has new rows
        t = c.sched_start + dt.timedelta(minutes=rng.randint(0, 59))
        while t < as_of:
            meta = meta_for(root, t, "TRIGGER")
            state, end, g_end, g_state, first_err = graph(root, t, meta)
            if state != "SKIPPED":
                graph_rows.append((root, t, g_end, g_state, first_err, meta, None))
            t = max(t + dt.timedelta(minutes=rng.uniform(20, 140)), g_end + MIN)

    for root, when, g_end, g_state, first_err, meta, nxt in graph_rows:
        b.au("COMPLETE_TASK_GRAPHS", root_task_name=root["name"], database_name=root["db"], schema_name=root["schema"],
             state=g_state if g_state != "SKIPPED" else "SUCCEEDED", scheduled_from=meta["sched_from"],
             first_error_task_name=first_err[0] if first_err else None,
             first_error_code=int(first_err[1][0]) if first_err and first_err[1] else None,
             first_error_message=first_err[1][1] if first_err and first_err[1] else None, scheduled_time=when,
             query_start_time=when + SEC, next_scheduled_time=nxt, completed_time=g_end, root_task_id=str(root["id"]),
             graph_version=meta["graph_v"], run_id=meta["run_id"], attempt_number=meta["attempt"],
             graph_run_group_id=meta["group"])

    # Serverless task credits: one row per task and hour, as the view bills them, plus the metering rows.
    by_id = {x["id"]: x for x in tl}
    for (tid, hr), credits in sorted(sl_hour.items()):
        x = by_id[tid]
        b.au("SERVERLESS_TASK_HISTORY", start_time=hr, end_time=hr + dt.timedelta(hours=1),
             credits_used=round(credits, 9), task_id=tid, task_name=x["name"], schema_id=c.schema_id.get((x["db"], x["schema"])),
             schema_name=x["schema"], database_id=c.db_id[x["db"]], database_name=x["db"])
        b.au("METERING_HISTORY", service_type="SERVERLESS_TASK", start_time=hr, end_time=hr + dt.timedelta(hours=1),
             entity_id=tid, entity_type="TASK", name=x["name"], database_id=c.db_id[x["db"]], database_name=x["db"],
             schema_id=c.schema_id.get((x["db"], x["schema"])), schema_name=x["schema"], credits_used_compute=credits,
             credits_used_cloud_services=0.0, credits_used=credits)
    _task_objects(c, tl)
    rid, rname, dropped = LEGACY_ROLE                 # the contractor role that owned the orphaned tasks
    b.au("ROLES", role_id=rid, name=rname, owner="USERADMIN", role_type="ROLE", owner_role_type="ROLE",
         created_on=b.ts(720, 9), deleted_on=b.ts(dropped, 16), comment=None, is_from_organization_user_group=False)
    return tl


def _history(c, x, when, state, start, end, qid, meta, cond, err_or_msg):
    if isinstance(err_or_msg, tuple):
        code, msg = err_or_msg
    else:
        code, msg = None, err_or_msg
    root = x["root_task"]
    c.b.au("TASK_HISTORY", name=x["name"], query_text=None, condition_text=cond, schema_name=x["schema"],
           task_schema_id=c.schema_id.get((x["db"], x["schema"])), database_name=x["db"], task_database_id=c.db_id[x["db"]],
           scheduled_time=when, completed_time=end or when, query_start_time=start, state=state, return_value=None,
           query_id=qid, error_code=code, error_message=msg, graph_version=meta["graph_v"], run_id=meta["run_id"],
           root_task_id=str(root["id"] if root else x["id"]), scheduled_from=meta["sched_from"],
           attempt_number=meta["attempt"], instance_id=1, graph_run_group_id=meta["group"])


def _task_objects(c: _Ctx, tl: list[dict]) -> None:
    """TASK_VERSIONS, ACCOUNT_USAGE.TASKS and SHOW TASKS for every demo task."""
    b = c.b
    svc = {team: c.users.get(f"SVC_{team}_INGEST", {}).get("user_id") for team in c.cat["teams"]}
    gone = next((u["user_id"] for u in c.users.values() if u.get("disabled") is True and u["user_id"] >= 50000), 59999)
    for x in tl:
        p = x["p"]
        root = x["root_task"]
        graph_root = root if root and x["story"] != "finalizer" else (root or x)
        preds = [root["fqn"]] if root and x["story"] != "finalizer" else []
        state = "suspended" if x["suspended"] else "started"
        susp_days = p.get("suspended_days")
        last_susp = b.ts(susp_days, 8) if susp_days is not None else None
        created = b.ts(60 if x["story"] == "never_ran" else 240, 9)
        committed = b.ts(p["changed_days"], 10) if p.get("changed_days") else b.ts(200, 10)
        root_id = str(root["id"] if root else x["id"])
        stream = p.get("stream")
        cond = f"SYSTEM$STREAM_HAS_DATA('STAGING.S_{stream}')" if stream else None
        overlap = p.get("overlap", "NO_OVERLAP")
        err_int = p.get("err_int") if not root else None
        rel = {"Predecessors": preds}
        if x["name"] == "OPS_LOAD_01":
            rel["FinalizerTask"] = "OPS_PROD_DB.STAGING.OPS_LOAD_FINALIZE"
        if x["story"] == "finalizer":
            rel["FinalizedRootTask"] = "OPS_PROD_DB.STAGING.OPS_LOAD_01"
        # a version covers the whole graph: a change to the root makes version 2 for every task in it
        changed = graph_root["p"].get("changed_days")
        versions = [(1, b.ts(200, 10))] + ([(2, b.ts(changed, 10))] if changed else [])
        for gv, created_on in versions:
            b.au("TASK_VERSIONS", root_task_id=root_id, graph_version=gv, graph_version_created_on=created_on,
                 name=x["name"], id=str(x["id"]), database_id=c.db_id[x["db"]], database_name=x["db"],
                 schema_id=c.schema_id.get((x["db"], x["schema"])), schema_name=x["schema"], owner=x["owner"],
                 comment=None, warehouse_name=x["warehouse"], schedule=x["schedule"], predecessors=preds or None,
                 state=state if gv == len(versions) else "started", definition=None, condition_text=cond,
                 allow_overlapping_execution=overlap == "ALLOW_ALL_OVERLAP", error_integration=err_int,
                 last_committed_on=created_on, last_suspended_on=last_susp if gv == len(versions) else None,
                 target_completion_interval=None, scheduling_mode=None)
        b.au("TASKS", created=created, last_altered=committed, deleted=None, id=str(x["id"]), task_name=x["name"],
             task_database_id=c.db_id[x["db"]], task_database=x["db"], task_schema_id=c.schema_id.get((x["db"], x["schema"])),
             task_schema=x["schema"], task_owner=x["owner"], comment=None, warehouse=x["warehouse"], schedule=x["schedule"],
             predecessors=preds, state=state, definition=None, condition=cond,
             allow_overlapping_execution=overlap == "ALLOW_ALL_OVERLAP", error_integration=err_int,
             last_committed=committed, last_suspended=last_susp, owner_role_type="ROLE", task_relations=rel,
             last_suspended_reason=p.get("reason"), execute_as_user_id=gone if p.get("run_as_gone") else svc.get(x["team"]),
             overlap_policy=overlap)
        target = x["target"][0] if x.get("target") else f"{x['db']}.{x['schema']}.{x['name']}_T"
        src = x["base"][0]["objectName"] if x.get("base") else f"{x['db']}.RAW.SRC"
        defn = (f"INSERT INTO {target} SELECT * FROM {x['db']}.STAGING.S_{stream}" if stream
                else f"MERGE INTO {target} USING {src} ON 1 = 1")
        b.show("tasks", created_on=created, name=x["name"], id=str(x["id"]), database_name=x["db"], schema_name=x["schema"],
               owner=x["owner"], comment="", warehouse=x["warehouse"], schedule=x["schedule"],
               predecessors=("[" + ", ".join(f'"{q}"' for q in preds) + "]") if preds else "[]", state=state,
               definition=defn, condition=cond, allow_overlapping_execution="true" if overlap == "ALLOW_ALL_OVERLAP" else "false",
               error_integration=err_int, last_committed_on=committed, last_suspended_on=last_susp, owner_role_type="ROLE",
               last_suspended_reason=p.get("reason"))


# ---------------------------------------------------------------------------------------------------------------------
# Snowpipe and COPY
# ---------------------------------------------------------------------------------------------------------------------
# files per day, avg MB, credits per 30 days, p95-ish latency s, error rate (catalog's unless set), stop days ago
PIPE_PROFILE = {
    "RISK_PIPE_1": dict(files=250, mb=180, credits=210, lat=60, ext="avro"),
    "RISK_PIPE_2": dict(files=100, mb=3, credits=6, lat=45),
    "PLATFORM_PIPE_1": dict(files=480, mb=0.4, credits=25, lat=30, on_error="CONTINUE"),
    "SALES_PIPE_1": dict(files=30, mb=60, credits=2, lat=420, ext="csv.gz"),
    "SALES_PIPE_2": dict(files=250, mb=8, credits=8, lat=50, stop=9, fail_last=True),
    "OPS_PIPE_1": dict(files=250, mb=25, credits=30, lat=90, slow_share=0.08),
    "OPS_PIPE_2": dict(files=250, mb=120, credits=14, lat=40, ext="parquet"),
    "OPS_PIPE_3": dict(files=100, mb=30, credits=3, lat=60, stop=12, auto=False),
    "MARKETING_PIPE_1": dict(files=100, mb=15, credits=9, lat=70, grow=3.0),
    "FINANCE_PIPE_1": dict(files=250, mb=40, credits=10, lat=35),
    "FINANCE_PIPE_2": dict(files=30, mb=5, credits=1, lat=55, on_error="CONTINUE", ext="csv.gz"),
}
COPY_ERRORS = [("Numeric value 'N/A' is not recognized", "AMOUNT"),
               ("End of record reached while expected to parse column '\"{t}\"[\"UPDATED_AT\":7]'", "UPDATED_AT"),
               ("Field delimiter ',' found while expecting record delimiter '\\n'", "DESCRIPTION"),
               ("Error parsing JSON: incomplete object value, pos 4096", None),
               ("Timestamp '2026-13-01 00:00:00' is not recognized", "EVENT_TS")]
ERRORS_BY_TYPE = {"json.gz": (0, 3, 4), "csv.gz": (0, 1, 2, 4), "parquet": (0, 4), "avro": (0, 4)}


def _copy_error(rng, ext: str, table: str) -> tuple[str, str | None]:
    msg, col = COPY_ERRORS[rng.choice(ERRORS_BY_TYPE[ext])]
    return msg.replace("{t}", table), col


def pipes(c: _Ctx) -> None:
    b, rng = c.b, c.rng
    MB = 1024 ** 2
    plist = [dict(p) for p in c.cat["pipes"]]
    plist.append(dict(id=80101, name="OPS_PIPE_LEGACY", db="OPS_PROD_DB", schema="RAW", team="OPS", files_per_day=0,
                      error_rate=0.0, dropped=45, prof=dict(files=150, mb=20, credits=12, lat=60)))
    plist.append(dict(id=80102, name="MARKETING_PIPE_2", db="MARKETING_PROD_DB", schema="RAW", team="MARKETING",
                      files_per_day=0, error_rate=0.0, created=3, prof=dict(files=0, mb=10, credits=0, lat=60)))
    for i, p in enumerate(plist):
        prof = p.get("prof") or PIPE_PROFILE[p["name"]]
        auto = prof.get("auto", True)
        ext = prof.get("ext", "json.gz")
        cont = prof.get("on_error") == "CONTINUE"          # Snowpipe's default is SKIP_FILE: a bad file fails
        tbls = c.old_tables(p["db"], "RAW")                # a table that was there before the pipe loaded into it
        tgt = tbls[i % len(tbls)] if tbls else None
        tname = tgt["name"] if tgt else "EVENTS"
        dropped_at = b.ts(p["dropped"], 9) if p.get("dropped") else None
        b.au("PIPES", pipe_id=p["id"], pipe_name=p["name"], pipe_schema_id=c.schema_id.get((p["db"], "RAW")),
             pipe_schema="RAW", pipe_catalog_id=c.db_id[p["db"]], pipe_catalog=p["db"],
             is_autoingest_enabled="YES" if auto else "NO",
             notification_channel_name="arn:aws:sqs:us-east-1:000000000000:sf-snowpipe-demo" if auto else None,
             pipe_owner=f"{p['team']}_ADMIN", definition=None, created=b.ts(p.get("created", 300), 9),
             last_altered=b.ts(min(p.get("created", 300), 40), 9), comment=None,
             pattern=".*[.]" + ext.replace(".", "[.]") if auto else None, deleted=dropped_at, owner_role_type="ROLE")
        if not prof["files"]:
            continue
        stage = f"s3://demo-landing-{p['team'].lower().replace('_', '-')}/{p['name'].lower()}/"
        per_file_cr = prof["credits"] / 30 / prof["files"]
        err_rate = p["error_rate"]
        for k in range(DAYS, 0, -1):
            if p.get("dropped") and k < p["dropped"]:
                continue
            if prof.get("stop") and k < prof["stop"]:
                continue
            d = b.back(k)
            growth = prof.get("grow", 1.0) if k <= 30 else 1.0
            n_day = max(1, int(prof["files"] * rng.uniform(0.8, 1.2) * (growth ** 0.5)))
            hours = list(range(24)) if n_day >= 48 else sorted(rng.sample(range(24), 6))
            if dropped_at and k == p["dropped"]:
                hours = [h for h in hours if h < dropped_at.hour]   # nothing loads after the drop
                if not hours:
                    continue
            per_hour = defaultdict(int)
            for _ in range(n_day):
                per_hour[rng.choice(hours)] += 1
            for h, n in sorted(per_hour.items()):
                loaded, gb_bytes = 0, 0
                for _ in range(n):
                    size = int(max(0.01, rng.lognormvariate(0, 0.35)) * prof["mb"] * MB)
                    lat = prof["lat"] * rng.uniform(0.3, 1.3)
                    if prof.get("slow_share") and rng.random() < prof["slow_share"]:
                        lat = rng.uniform(1900, 3200)
                    status, err, ecount = "Loaded", None, 0
                    last_stretch = prof.get("fail_last") and k <= prof["stop"] + 2
                    rows = max(1, size // 300)
                    if last_stretch or rng.random() < err_rate:
                        status = "Partially loaded" if cont and not last_stretch and rng.random() < 0.7 else "Load failed"
                        err = _copy_error(rng, ext, tname)
                        ecount = rng.randint(1, 40) if status == "Partially loaded" else rows
                    if status != "Load failed":
                        loaded += 1
                        gb_bytes += size
                    if k > DETAIL_DAYS:
                        continue                         # COPY_HISTORY rows only where the checks look
                    recv = dt.datetime(d.year, d.month, d.day, h, rng.randint(0, 59), rng.randint(0, 59))
                    commit = recv + dt.timedelta(seconds=lat)
                    b.au("COPY_HISTORY", file_name=f"{p['name'].lower()}/{d.isoformat()}/{h:02d}/part-{rng.randint(0, 99999):05d}.{ext}",
                         stage_location=stage, last_load_time=commit, row_count=rows - ecount if status != "Load failed" else 0,
                         row_parsed=rows, file_size=size, first_error_message=err[0] if err else None,
                         first_error_line_number=rng.randint(1, 5000) if err else None,
                         first_error_character_pos=rng.randint(1, 200) if err else None,
                         first_error_column_name=err[1] if err else None, error_count=ecount,
                         error_limit=rows if cont or not auto else 1,
                         status=status, table_id=tgt["id"] if tgt else None, table_name=tname,
                         table_schema_id=c.schema_id.get((p["db"], "RAW")), table_schema_name="RAW",
                         table_catalog_id=c.db_id[p["db"]], table_catalog_name=p["db"], pipe_catalog_name=p["db"],
                         pipe_schema_name="RAW", pipe_name=p["name"], pipe_received_time=recv, first_commit_time=commit,
                         bytes_billed=size)
                if not loaded:
                    continue
                credits = loaded * per_file_cr * growth ** 0.5 * rng.uniform(0.85, 1.15)
                hr = b.ts(k, h)
                b.au("PIPE_USAGE_HISTORY", pipe_id=p["id"], pipe_name=p["name"], start_time=hr,
                     end_time=hr + dt.timedelta(hours=1), credits_used=credits, bytes_inserted=float(gb_bytes),
                     files_inserted=loaded, bytes_billed=gb_bytes)
                b.au("METERING_HISTORY", service_type="PIPE", start_time=hr, end_time=hr + dt.timedelta(hours=1),
                     entity_id=p["id"], entity_type="PIPE", name=p["name"], database_id=c.db_id[p["db"]],
                     database_name=p["db"], schema_id=c.schema_id.get((p["db"], "RAW")), schema_name="RAW",
                     credits_used_compute=credits, credits_used_cloud_services=0.0, credits_used=credits,
                     bytes=gb_bytes, files=loaded)

    # Bulk COPY from the daily task loads: one stage per team. ON_ERROR differs: CONTINUE loads what it can,
    # SKIP_FILE_10 skips a file with 10 or more bad rows, ABORT_STATEMENT (the default) fails the file.
    on_error = {"MARKETING": "CONTINUE", "DATA_SCIENCE": "SKIP_FILE_10", "OPS": "CONTINUE"}
    for t_i, team in enumerate(c.cat["teams"]):
        db = f"{team}_PROD_DB"
        tbls = c.old_tables(db, "STAGING")
        if not tbls:
            continue
        tgt = tbls[0]
        bad = {"FINANCE": 0.0, "MARKETING": 0.04, "SALES": 0.0, "PLATFORM": 0.0, "DATA_SCIENCE": 0.12,
               "PRODUCT": 0.0, "RISK": 0.01, "OPS": 0.02}[team]
        mode = on_error.get(team, "ABORT_STATEMENT")
        ext = "parquet" if team in ("PRODUCT", "PLATFORM") else "csv.gz"
        for k in range(1, DETAIL_DAYS + 1):
            d = b.back(k)
            for f in range(3):
                size = int(rng.uniform(80, 260) * MB)
                rows = size // 250
                st, err, ec = "Loaded", None, 0
                limit = rows if mode == "CONTINUE" else (10 if mode == "SKIP_FILE_10" else 1)
                if rng.random() < bad:
                    err, ec = _copy_error(rng, ext, tgt["name"]), rng.randint(1, 900)
                    if mode == "CONTINUE":
                        st = "Partially loaded" if rng.random() < 0.8 else "Load failed"
                    elif mode == "SKIP_FILE_10":
                        st = "Load skipped" if ec >= 10 else "Partially loaded"
                    else:
                        st = "Load failed"
                loaded = st in ("Loaded", "Partially loaded")
                b.au("COPY_HISTORY", file_name=f"exports/{d.isoformat()}/part_{f}.{ext}",
                     stage_location=f"s3://demo-exports-{team.lower().replace('_', '-')}/daily/",
                     last_load_time=b.ts(k, 2, 10 + f * 3), row_count=rows - ec if loaded else 0, row_parsed=rows,
                     file_size=size, first_error_message=err[0] if err else None,
                     first_error_line_number=rng.randint(1, 90000) if err else None,
                     first_error_column_name=err[1] if err else None, error_count=ec, error_limit=limit, status=st,
                     table_id=tgt["id"], table_name=tgt["name"], table_schema_id=tgt["schema_id"], table_schema_name="STAGING",
                     table_catalog_id=c.db_id[db], table_catalog_name=db, bytes_billed=size)


def streaming(c: _Ctx) -> None:
    """Snowpipe Streaming: two clients (one costly), three channels (healthy, slow, rejecting rows)."""
    b, rng = c.b, c.rng
    channels = ((80301, "EVENTS_CH_0", "PRODUCT_PROD_DB", 0, 4_000, 80201),
                (80302, "IOT_CH_0", "OPS_PROD_DB", 0, 95_000, 80202),
                (80303, "CLICKS_CH_0", "MARKETING_PROD_DB", 250, 6_000, 80201))
    target = {cid: (c.old_tables(db, "RAW") or [None])[0] for cid, _, db, *_ in channels}
    for eid, client, per_day in ((80201, "kafka-connector-events", 2.2), (80202, "ingest-sdk-iot", 0.25)):
        mine = [ch for ch in channels if ch[5] == eid]
        for k in range(DAYS, 0, -1):
            credits = per_day * rng.uniform(0.8, 1.2) * (1.4 if k <= 30 and eid == 80201 else 1.0)
            nbytes, nrows = int(credits * 3e10), int(credits * 5e7)
            hr = b.ts(k, 12)
            b.au("METERING_HISTORY", service_type="SNOWPIPE_STREAMING", start_time=hr, end_time=hr + dt.timedelta(hours=1),
                 entity_id=eid, entity_type="SNOWPIPE_STREAMING", name=client, database_id=None, database_name=None,
                 schema_id=None, schema_name=None, credits_used_compute=credits, credits_used_cloud_services=0.0,
                 credits_used=credits, bytes=nbytes, rows=nrows, files=None)
            # file migration: part of those same credits, per target table (metered once, above)
            share = rng.uniform(0.10, 0.20)
            for cid, _, db, *_ in mine:
                t = target[cid]
                if t is None:
                    continue
                part = share / len(mine)
                b.au("SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY", start_time=b.ts(k, 13), end_time=b.ts(k, 14),
                     credits_used=credits * part, num_bytes_migrated=int(nbytes / len(mine) * rng.uniform(0.8, 1.0)),
                     num_rows_migrated=int(nrows / len(mine) * rng.uniform(0.8, 1.0)), table_id=t["id"],
                     table_name=t["name"], schema_id=c.schema_id.get((db, "RAW")), schema_name="RAW",
                     database_id=c.db_id[db], database_name=db)
            if k <= DETAIL_DAYS:
                for h in (3, 12, 20):
                    b.au("SNOWPIPE_STREAMING_CLIENT_HISTORY", client_name=client, snowflake_provided_id=f"sp-{eid}",
                         event_timestamp=b.ts(k, h, rng.randint(0, 59)), event_type="BLOB_PERSIST",
                         blob_size_bytes=int(rng.uniform(5e6, 6e7)))
    for cid, name, db, err_per, lat_ms, _ in channels:
        tbl = target[cid]
        parsed = 0
        errs = 0
        for k in range(DETAIL_DAYS - 1, 0, -3):
            parsed += int(rng.uniform(1e5, 3e5))
            errs += int(err_per * rng.uniform(0.5, 1.5))
            b.au("SNOWPIPE_STREAMING_CHANNEL_HISTORY", account_id=1, created_on=b.ts(k, 12), channel_id=cid,
                 channel_name=name, pipe_id=cid - 100, pipe_name=f"{name.split('_')[0]}_STREAMING_PIPE",
                 pipe_schema_id=c.schema_id.get((db, "RAW")), pipe_schema_name="RAW", pipe_database_id=c.db_id[db],
                 pipe_database_name=db, end_offset=str(parsed), table_id=tbl["id"] if tbl else None,
                 table_name=tbl["name"] if tbl else None, table_schema_id=c.schema_id.get((db, "RAW")),
                 table_schema_name="RAW", table_database_id=c.db_id[db], table_database_name=db,
                 last_error_offset_upper_bound=str(parsed - 10) if errs else None,
                 last_error_message="Row rejected: value does not match the column type" if errs else None,
                 snowflake_processing_latency_ms=int(lat_ms * rng.uniform(0.8, 1.2)), rows_inserted=parsed - errs,
                 rows_parsed=parsed, row_error_count=errs)


# ---------------------------------------------------------------------------------------------------------------------
# Dynamic tables
# ---------------------------------------------------------------------------------------------------------------------
DTS = [  # id, name, team, warehouse, target lag s, refresh every s (half the lag, as Snowflake schedules), mode, story
    (47001, "DT_REVENUE_DAILY", "FINANCE", "WH_FINANCE_ETL", 86400, 43200, "INCREMENTAL", "healthy"),
    (47002, "DT_PIPELINE_SNAPSHOT", "SALES", "WH_PLATFORM_ADHOC", 14400, 7200, "INCREMENTAL", "late"),
    (47003, "DT_CAMPAIGN_ATTRIBUTION", "MARKETING", "WH_PLATFORM_ADHOC", 3600, 1800, "INCREMENTAL", "failing"),
    (47004, "DT_FEATURE_STORE", "DATA_SCIENCE", "WH_DATA_SCIENCE_ETL", 3600, 1800, "FULL", "full_unread"),
    (47005, "DT_USAGE_ROLLUP", "PRODUCT", "WH_PLATFORM_ADHOC", 3600, 1800, "INCREMENTAL", "slow"),
    (47006, "DT_EXPOSURE", "RISK", "WH_RISK_ETL", 86400, 43200, "INCREMENTAL", "suspended_read"),
    (47007, "DT_TICKET_STATS", "OPS", "WH_OPS_ETL", 86400, 43200, "INCREMENTAL", "suspended_unread"),
    (47008, "DT_COST_ROLLUP", "PLATFORM", "WH_PLATFORM_ADHOC", 14400, 7200, "INCREMENTAL", "healthy"),
    (47009, "DT_LEADS_SCORED", "SALES", "WH_SALES_ETL", 86400, 43200, "INCREMENTAL", "dropped"),
]
LAG_TEXT = {86400: "1 day", 14400: "4 hours", 3600: "1 hour"}
CUSTOM_INCREMENTAL = {"DT_TICKET_STATS"}            # its refreshes report CUSTOM_INCREMENTAL
UPSTREAM = {"DT_COST_ROLLUP": "DT_USAGE_ROLLUP"}     # reads another dynamic table


def dynamic_tables(c: _Ctx) -> None:
    b, rng = c.b, c.rng
    GB = 1024 ** 3
    as_of = c.w.now.replace(hour=0)
    refreshes: dict[str, list] = defaultdict(list)   # name -> [(start, state)] for downstream tables
    by_name = {d[1]: d for d in DTS}
    for n_dt, (tid, name, team, wh, lag, every, mode, story) in enumerate(DTS):
        db = f"{team}_PROD_DB"
        sid = c.schema_id.get((db, "MARTS"))
        fqn = f"{db}.MARTS.{name}"
        susp_days = {"suspended_read": 10, "suspended_unread": 20}.get(story)
        dropped = 12 if story == "dropped" else None
        gb = {"full_unread": 180, "healthy": 6}.get(story, 25) * rng.uniform(0.7, 1.3)
        t = as_of - dt.timedelta(days=DAYS) + dt.timedelta(hours=3 if every == 43200 else 0)
        stop = as_of - dt.timedelta(days=susp_days or dropped or 0) if (susp_days or dropped) else as_of
        start_at = as_of - dt.timedelta(days=40) if dropped else t
        t = max(t, start_at)
        created = start_at if dropped else b.ts(240, 9)   # a new table's first refresh is its creation
        dropped_at = b.ts(dropped, 9) if dropped else None
        b.au("TABLES", table_id=tid, table_name=name, table_schema_id=sid, table_schema="MARTS",
             table_catalog_id=c.db_id[db], table_catalog=db, table_owner=f"{team}_ADMIN", table_type="BASE TABLE",
             is_transient="NO", clustering_key=None, auto_clustering_on="NO", row_count=int(gb * 4e6),
             bytes=int(gb * GB), retention_time=1, created=created, last_altered=b.ts(max(1, susp_days or 1), 4),
             last_ddl=created, last_ddl_by=f"{team}_ADMIN", deleted=dropped_at,
             is_iceberg="NO", is_dynamic="YES", is_hybrid="NO")
        # storage: refreshes rewrite part of the table; the old versions sit in Time Travel (1 day) and Fail-safe (7)
        churn = gb * (0.15 if mode == "FULL" else 0.04) * GB
        b.au("TABLE_STORAGE_METRICS", id=tid, table_name=name, table_schema_id=sid, table_schema="MARTS",
             table_catalog_id=c.db_id[db], table_catalog=db, clone_group_id=tid, is_transient="NO",
             active_bytes=0 if dropped else int(gb * GB), time_travel_bytes=0 if dropped or susp_days else int(churn),
             failsafe_bytes=0 if dropped else int(churn * (7 if not susp_days else max(0, 7 - susp_days + 1))),
             retained_for_clone_bytes=0, deleted=bool(dropped), table_created=created, table_dropped=dropped_at,
             table_entered_failsafe=dropped_at + dt.timedelta(days=1) if dropped_at else None)
        if not dropped:
            b.show("dynamic_tables", created_on=created, name=name, database_name=db, schema_name="MARTS",
                   cluster_by="", rows=int(gb * 4e6), bytes=int(gb * GB), owner=f"{team}_ADMIN",
                   target_lag=LAG_TEXT[lag], scheduler="ENABLE", refresh_mode=mode,
                   refresh_mode_reason="the query uses a non-deterministic function" if mode == "FULL" else None,
                   warehouse=wh, comment="", automatic_clustering="OFF",
                   scheduling_state="SUSPENDED" if susp_days else "RUNNING",
                   last_suspended_on=b.ts(susp_days, 7) if susp_days else None, is_clone="false", is_replica="false",
                   is_iceberg="false", data_timestamp=b.ts(susp_days or 0, 3) if susp_days or lag == 86400 else
                   as_of - dt.timedelta(seconds=every * rng.uniform(0.2, 0.9)),
                   owner_role_type="ROLE", execute_as_user=None)
        # what a refresh reads: the upstream dynamic table, or a staging table of the team
        if name in UPSTREAM:
            up = by_name[UPSTREAM[name]]
            src = [_obj(f"{up[2]}_PROD_DB.MARTS.{up[1]}", up[0])]
        else:
            pool = c.old_tables(db, "STAGING")
            src = [_obj(f"{db}.STAGING.{s['name']}", s["id"]) for s in pool[n_dt % max(1, len(pool)):][:2]] if pool else []
        up_hist = refreshes.get(UPSTREAM.get(name, ""), [])
        up_starts = [s for s, _ in up_hist]
        reinit_day = 30 + 7 * n_dt if mode == "INCREMENTAL" else None
        first = True
        while t < stop:
            delay = 0.0
            if story == "late" and rng.random() < 0.2:
                delay = rng.uniform(2.5, 4) * 3600
            start = t + dt.timedelta(seconds=delay)
            if story == "slow":
                secs = rng.uniform(1500, 3000) if (as_of - t).days < 25 else rng.uniform(300, 900)
            elif story == "full_unread":
                secs = rng.uniform(360, 560)
            else:
                secs = rng.uniform(20, 240) if every < 43200 else rng.uniform(300, 900)
            # the action first: only a refresh that does work can fail or be canceled
            if mode == "FULL":
                action = "FULL" if rng.random() < 0.9 else "NO_DATA"
            else:
                action = rng.choice(["INCREMENTAL"] * 5 + ["NO_DATA"] * 4 + ["FULL"])
                if action == "INCREMENTAL" and name in CUSTOM_INCREMENTAL:
                    action = "CUSTOM_INCREMENTAL"
            if first and dropped:
                action = "INCREMENTAL"                    # the initial build of a new table
            elif reinit_day and not dropped and start >= b.ts(reinit_day):
                action, secs = "REINITIALIZE", secs * 4   # a base table was replaced
                reinit_day = None
            trigger = "CREATION" if first and dropped else ("MANUAL" if rng.random() < 0.02 else "SCHEDULED")
            state, code, msg = "SUCCEEDED", None, None
            r = rng.random()
            if up_starts:
                j = bisect.bisect_right(up_starts, start) - 1
                if j >= 0 and up_hist[j][1] == "FAILED":
                    state, action = "UPSTREAM_FAILED", "NO_DATA"
            if state == "SUCCEEDED" and action != "NO_DATA":
                if story == "failing" and r < 0.45:
                    state, code, msg = "FAILED", "002003", \
                        "SQL compilation error: Object 'MARKETING_PROD_DB.RAW.CAMPAIGNS_V2' does not exist or not authorized."
                elif r < 0.012:
                    state, code, msg = "FAILED", "000630", ERRORS[0][1]
                elif r > 0.996:
                    state, code, msg = "CANCELLED", "000604", ERRORS[CANCELED][1]   # warehouse suspended mid-refresh
                    secs *= rng.uniform(0.1, 0.5)
            if action == "NO_DATA":
                secs = rng.uniform(0.5, 4)
            qid = None
            if action != "NO_DATA":
                qid = c.qid("d")
                c.stmt(qid, wh, start, secs, "MERGE" if "INCREMENTAL" in action else "INSERT", f"{team}_ADMIN", db,
                       "MARTS", ok=state == "SUCCEEDED", err=(code, msg) if code else None,
                       rows_changed=int(rng.uniform(1e4, 2e6)), hkey=fqn, sess_key=tid)
                if state == "SUCCEEDED" and start >= c.detail_start:
                    c.access(qid, start, src, src, (fqn, tid))
            refreshes[name].append((start, state))
            end = start + dt.timedelta(seconds=secs)
            b.au("DYNAMIC_TABLE_REFRESH_HISTORY", name=name, schema_name="MARTS", database_name=db, id=tid, schema_id=sid,
                 database_id=c.db_id[db], qualified_name=fqn, state=state, state_code=code, state_message=msg,
                 query_id=qid, data_timestamp=start, refresh_start_time=start, refresh_end_time=end,
                 completion_target=start + dt.timedelta(seconds=lag), statistics={"numInsertedRows": int(rng.uniform(0, 5e5))},
                 refresh_action=action, refresh_trigger=trigger, target_lag_sec=lag)
            first = False
            t += dt.timedelta(seconds=every)

    # Reads: people read the healthy tables; the suspended DT_EXPOSURE is still read after it stopped;
    # DT_FEATURE_STORE and DT_TICKET_STATS are read by nobody. Readers are people who signed in lately.
    recent = b.ts(1)
    readers = sorted(u for u, r in c.users.items() if not u.startswith("SVC_") and r["user_id"] >= 50000
                     and r.get("type") == "PERSON" and not r.get("disabled") and r.get("deleted_on") is None
                     and r.get("last_success_login") and r["last_success_login"] >= recent)
    reads = {"DT_REVENUE_DAILY": 40, "DT_PIPELINE_SNAPSHOT": 25, "DT_CAMPAIGN_ATTRIBUTION": 15, "DT_COST_ROLLUP": 20,
             "DT_EXPOSURE": 9, "DT_USAGE_ROLLUP": 6}
    for name, n in reads.items():
        tid, _, team, *_ = by_name[name]
        fqn = f"{team}_PROD_DB.MARTS.{name}"
        for _ in range(n):
            k = rng.randint(1, 9) if name == "DT_EXPOSURE" else rng.randint(1, 29)
            obj = [_obj(fqn, tid)]
            at = b.ts(k, rng.randint(8, 18), rng.randint(0, 59))
            user = rng.choice(readers)
            at = min(at, c.users[user]["last_success_login"] - MIN)   # a read never post-dates the reader's last sign-in
            c.access(c.qid("r"), at, obj, obj, user=user)


# ---------------------------------------------------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------------------------------------------------
ALERTS = [  # id, name, team, warehouse, every min, state, story
    (80401, "ALERT_LATE_LOAD", "FINANCE", "WH_FINANCE_ETL", 60, "started", "ok"),
    (80402, "ALERT_CREDIT_SPIKE", "PLATFORM", None, 15, "started", "costly"),
    (80403, "ALERT_EXPOSURE_LIMIT", "RISK", None, 60, "started", "failing"),
    (80404, "ALERT_QUOTA_BREACH", "SALES", None, 60, "suspended", "auto_suspended"),
    (80405, "ALERT_TICKET_SLA", "OPS", "WH_OPS_ETL", 60, "suspended", "old_off"),
    (80406, "ALERT_BUDGET_80", "MARKETING", None, 60, "started", "never"),
    (80407, "ALERT_MODEL_DRIFT", "DATA_SCIENCE", None, 1440, "started", "ok"),
]
NO_WH_MSG = ("No active warehouse selected in the current session.  Select an active warehouse with the "
             "'use warehouse' command.")
FIXED_DAYS = 2                                    # ALERT_EXPOSURE_LIMIT's condition was fixed this long ago


def alerts(c: _Ctx) -> None:
    b, rng = c.b, c.rng
    for aid, name, team, wh, every, state, story in ALERTS:
        db = f"{team}_PROD_DB"
        sid = c.schema_id.get((db, "MARTS"))
        b.show("alerts", created_on=b.ts(200 if story != "never" else 60, 9), name=name, database_name=db, schema_name="MARTS",
               owner=f"{team}_ADMIN", comment="", warehouse=wh, schedule=f"{every} MINUTE" if every < 1440 else "USING CRON 0 7 * * * UTC",
               state=state, condition=None, action=None, owner_role_type="ROLE", runbook=None, config=None,
               was_auto_suspended="true" if story == "auto_suspended" else "false")
        if story == "never":
            continue
        first, last = {"auto_suspended": (DAYS, 15), "old_off": (110, 50)}.get(story, (DAYS, 0))
        sl = defaultdict(float)
        t = b.ts(first, 0)
        stop = b.ts(last, 0) if last else c.w.now.replace(hour=0)
        fixed = b.ts(FIXED_DAYS, 9)
        runs = []
        while t < stop:
            r = rng.random()
            st = "CONDITION_FALSE"
            if story == "failing" and r < 0.3 and t < fixed or story == "auto_suspended" and r < 0.5:
                st = "CONDITION_FAILED"
            elif r > 0.997 and story != "ok":
                st = "ACTION_FAILED"
            elif r > 0.94:
                st = "TRIGGERED"
            runs.append((t, st, "SCHEDULE"))
            t += dt.timedelta(minutes=every)
        if story == "auto_suspended":
            runs[-10:] = [(tt, "CONDITION_FAILED", s) for tt, _, s in runs[-10:]]   # the failures that suspended it
        if story == "old_off":
            runs[-8:] = [(tt, "FAILED", s) for tt, _, s in runs[-8:]]     # no usable warehouse: it could not start
        if story == "costly":
            for j in (len(runs) // 3, 2 * len(runs) // 3):
                runs[j] = (runs[j][0], "CANCELLED", "SCHEDULE")
        if story == "failing":                                         # checked by hand after the fix
            runs += [(fixed + dt.timedelta(minutes=20 * j + rng.randint(0, 9)), "CONDITION_FALSE" if j < 3 else "TRIGGERED",
                      "EXECUTE ALERT") for j in range(4)]
            runs.sort()
        for i, (tt, st, sched_from) in enumerate(runs):
            failed = st in ("CONDITION_FAILED", "ACTION_FAILED")
            code, msg = None, None
            if failed:
                code, msg = 2003, f"SQL compilation error: Object '{db}.MARTS.{team}_LIMITS' does not exist or not authorized."
            elif st == "FAILED":
                code, msg = 606, NO_WH_MSG
            elif st == "CANCELLED":
                code, msg = 604, ERRORS[CANCELED][1]
            ran = st not in ("FAILED",)
            b.au("ALERT_HISTORY", name=name, database_name=db, schema_name="MARTS", action=None,
                 action_query_id=c.qid("a") if st in ("TRIGGERED", "ACTION_FAILED") else None, condition=None,
                 condition_query_id=c.qid("c") if ran else None, error_code=code, error_message=msg,
                 state=st, scheduled_time=tt, completed_time=tt + dt.timedelta(seconds=rng.randint(3, 40) if ran else 1),
                 database_id=c.db_id[db], schema_id=sid, scheduled_from=sched_from, runbook=None,
                 was_auto_suspended=story == "auto_suspended" and i == len(runs) - 1, config=None)
            if wh is None and ran:
                level = 0.012 if story == "costly" and tt >= b.ts(60) else (0.008 if story == "costly" else 0.002)
                sl[tt.replace(minute=0)] += level * rng.uniform(0.7, 1.3)
        for hr, cr in sorted(sl.items()):
            b.au("SERVERLESS_ALERT_HISTORY", start_time=hr, end_time=hr + dt.timedelta(hours=1), credits_used=round(cr, 9),
                 alert_id=aid, alert_name=name, schema_id=sid, schema_name="MARTS", database_id=c.db_id[db],
                 database_name=db)
            b.au("METERING_HISTORY", service_type="SERVERLESS_ALERTS", start_time=hr, end_time=hr + dt.timedelta(hours=1),
                 entity_id=aid, entity_type="ALERT", name=name, database_id=c.db_id[db], database_name=db,
                 schema_id=sid, schema_name="MARTS", credits_used_compute=cr, credits_used_cloud_services=0.0,
                 credits_used=cr)


def add(b) -> None:
    c = _Ctx(b)
    ssrc = _stream_sources(c)
    tl = tasks(c, ssrc)
    streams(c, ssrc)
    pipes(c)
    streaming(c)
    dynamic_tables(c)
    alerts(c)
    # its own random stream: DT lag and DOWNSTREAM orphans, late task starts, pipe alerts, COPY loads
    demo_pipe_fit.add(c, tl)
