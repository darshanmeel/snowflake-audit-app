"""Demo pipeline fit: dynamic-table lag, DOWNSTREAM orphans, late task starts, pipe alerts, COPY loads.

Called last from demo_pipelines.add, with its own random stream, so nothing before it draws different numbers.
- RISK_DEV_DB.SCRATCH.DT_RISK_LIMITS_DEV: a dev dynamic table with a 10-minute lag on WH_RISK_DEV (auto-suspend
  10 minutes). It refreshes every 5 to 9 minutes, so the warehouse has not suspended since it was built 26 days
  ago; nobody reads it. It reads DT_RISK_EXPOSURE_STG (DOWNSTREAM), which refreshes with it.
- SALES_PROD_DB.MARTS.DT_LEADS_ENRICHED (DOWNSTREAM): its consumer was dropped, so it has not refreshed since it
  was built 75 days ago. DATA_SCIENCE_PROD_DB.MARTS.DT_CHURN_FEATURES (DOWNSTREAM): built 5 days ago, no consumer.
- PLATFORM_LOAD_02 queues behind the 02:00 PLATFORM_LOAD_01 graph on WH_PLATFORM_ETL; SALES_LOAD_02 (serverless,
  hourly) starts minutes late at the top of the hour; OPS_LOAD_02 waits a few seconds for WH_OPS_ETL to resume.
- SHOW PIPES: SALES_PIPE_2 went invalid when its stage was dropped (it also stopped loading); three pipes send
  their load errors to a notification integration, the other auto-ingest pipes do not.
- COPY: SVC_PLATFORM_INGEST copies a few MB into PLATFORM_PROD_DB.RAW every 5 minutes on WH_PLATFORM_ADHOC (a job
  Snowpipe would do for less); each team's 02:10 bulk COPY now has its statement, and MARKETING's lists a whole
  bucket prefix of three years of exports before it loads three files.
"""
from __future__ import annotations

import datetime as dt
import random

from tests.fake_snowflake import demo_entities
from tests.fake_snowflake.data import RATE

HOUR = dt.timedelta(hours=1)
MB = 1024 ** 2
LIVE = (47011, "DT_RISK_LIMITS_DEV", "WH_RISK_DEV", 600, 26)        # id, name, warehouse, target lag s, days
STG = (47012, "DT_RISK_EXPOSURE_STG")
ORPHANS = [  # id, name, team, warehouse, days since it was built
    (47013, "DT_LEADS_ENRICHED", "SALES", "WH_SALES_ETL", 75),
    (47014, "DT_CHURN_FEATURES", "DATA_SCIENCE", "WH_DATA_SCIENCE_ETL", 5),
]
QUEUED = ("PLATFORM_LOAD_02", 12 * 60, 40 * 60)                     # task, queue seconds low/high
SCHED_LAG = ("SALES_LOAD_02", 150, 540)                              # task, scheduler delay seconds low/high
RESUME = ("OPS_LOAD_02", 1, 6)                                       # task, resume seconds low/high
ERROR_INTEGRATIONS = {"RISK_PIPE_1": "ERR_NOTIFY_RISK", "FINANCE_PIPE_1": "ERR_NOTIFY_FINANCE",
                      "OPS_PIPE_2": "ERR_NOTIFY_OPS"}
INVALID = {"SALES_PIPE_2": "Pipe stage SALES_PROD_DB.RAW.SALES_LANDING was dropped or is no longer authorized."}
FREQUENT_COPY = ("WH_PLATFORM_ADHOC", "SVC_PLATFORM_INGEST", "PLATFORM", 40, 300)   # warehouse, user, team, days, every s
WIDE_PREFIX = "MARKETING"                                            # the team whose daily COPY lists a whole prefix


def add(c, tl: list[dict]) -> None:
    rng = random.Random(f"{demo_entities.DEMO_SEED}:pipe-fit")
    _dt_lag(c, rng)
    _dt_orphans(c, rng)
    _task_delays(c, rng)
    _show_pipes(c)
    _copies(c, rng)


def _bill(c, w, hour: dt.datetime, compute: float) -> None:
    """Raise one warehouse hour's billed compute to `compute` (a missing hour is created) and its headroom."""
    b = c.b
    rows = b.w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]
    mh = b.w.rows[("account_usage", "METERING_HISTORY")]
    if not hasattr(c, "_pf_idx"):
        m_by = {(x.get("entity_id"), x["start_time"]): x for x in mh if x["service_type"] == "WAREHOUSE_METERING"}
        c._pf_idx = {(x["warehouse_id"], x["start_time"]): (x, m_by.get((x["warehouse_id"], x["start_time"])))
                     for x in rows}
    key = (w["id"], hour)
    if key not in c._pf_idx:
        r = dict(start_time=hour, end_time=hour + HOUR, warehouse_id=w["id"], warehouse_name=w["name"],
                 credits_used=0.0, credits_used_compute=0.0, credits_used_cloud_services=0.0,
                 credits_attributed_compute_queries=0.0)
        m = dict(service_type="WAREHOUSE_METERING", start_time=hour, end_time=hour + HOUR, entity_id=w["id"],
                 entity_type="WAREHOUSE", name=w["name"], credits_used_compute=0.0, credits_used_cloud_services=0.0,
                 credits_used=0.0)
        rows.append(r)
        mh.append(m)
        c._pf_idx[key] = (r, m)
    r, m = c._pf_idx[key]
    extra = max(0.0, compute - r["credits_used_compute"])
    for t in (r, m):
        if t is not None:
            t["credits_used_compute"] += extra
            t["credits_used"] += extra
    c.headroom[key] = max(0.0, r["credits_used_compute"] - (r.get("credits_attributed_compute_queries") or 0.0))


def _dt_rows(c, tid, name, db, schema, wh, lag, created, owner, data_ts=None):
    """TABLES and SHOW DYNAMIC TABLES for one demo dynamic table; lag None is DOWNSTREAM."""
    b = c.b
    sid = c.schema_id.get((db, schema))
    gb = 2.0
    b.au("TABLES", table_id=tid, table_name=name, table_schema_id=sid, table_schema=schema,
         table_catalog_id=c.db_id[db], table_catalog=db, table_owner=owner, table_type="BASE TABLE",
         is_transient="NO", clustering_key=None, auto_clustering_on="NO", row_count=int(gb * 4e6),
         bytes=int(gb * 1024 ** 3), retention_time=1, created=created, last_altered=data_ts or created,
         last_ddl=created, last_ddl_by="SYSTEM", deleted=None, is_iceberg="NO", is_dynamic="YES", is_hybrid="NO")
    b.show("dynamic_tables", created_on=created, name=name, database_name=db, schema_name=schema, cluster_by="",
           rows=int(gb * 4e6), bytes=int(gb * 1024 ** 3), owner=owner,
           target_lag="DOWNSTREAM" if lag is None else f"{lag // 60} minutes", scheduler="ENABLE",
           refresh_mode="INCREMENTAL", refresh_mode_reason=None, warehouse=wh, comment="", automatic_clustering="OFF",
           scheduling_state="RUNNING", last_suspended_on=None, is_clone="false", is_replica="false",
           is_iceberg="false", data_timestamp=data_ts or created, owner_role_type="ROLE", execute_as_user=None)


def _refresh(c, tid, name, db, schema, wh, start, secs, action, trigger, lag, role, src, rng):
    """One refresh: its statement on the warehouse (unless NO_DATA) and its refresh history row."""
    from tests.fake_snowflake.demo_pipelines import _obj
    b = c.b
    fqn = f"{db}.{schema}.{name}"
    qid = None
    if action != "NO_DATA":
        qid = c.qid("d")
        c.stmt(qid, wh, start, secs, "MERGE", role, db, schema, rows_changed=int(rng.uniform(1e3, 8e4)), hkey=fqn,
               sess_key=tid)
        if start >= c.detail_start and src:
            c.access(qid, start, src, src, (fqn, tid))
    end = start + dt.timedelta(seconds=secs)
    b.au("DYNAMIC_TABLE_REFRESH_HISTORY", name=name, schema_name=schema, database_name=db, id=tid,
         schema_id=c.schema_id.get((db, schema)), database_id=c.db_id[db], qualified_name=fqn, state="SUCCEEDED",
         state_code=None, state_message=None, query_id=qid, data_timestamp=start, refresh_start_time=start,
         refresh_end_time=end, completion_target=start + dt.timedelta(seconds=lag or 600),
         statistics={"numInsertedRows": int(rng.uniform(0, 5e4))}, refresh_action=action,
         refresh_trigger=trigger, target_lag_sec=lag)
    return _obj(fqn, tid)


def _dt_lag(c, rng) -> None:
    from tests.fake_snowflake.demo_pipelines import _obj
    b = c.b
    tid, name, wh_name, lag, days = LIVE
    w = c.wh[wh_name]
    db, schema = "RISK_DEV_DB", "SCRATCH"
    as_of = c.w.now.replace(hour=0, minute=0, second=0, microsecond=0)
    created = b.ts(days, 10, 12)
    # up from the first refresh to the as-of date: every hour billed in full
    hour = created.replace(minute=0)
    while hour < as_of:
        _bill(c, w, hour, float(RATE[w["size"]]))
        hour += HOUR
    raw = c.old_tables("RISK_PROD_DB", "RAW")
    raw_obj = [_obj(f"RISK_PROD_DB.RAW.{raw[0]['name']}", raw[0]["id"])] if raw else []
    stg_obj = [_obj(f"{db}.{schema}.{STG[1]}", STG[0])]
    t, n, last, last_stg = created, 0, created, created
    while t < as_of:
        first = n == 0
        # the DOWNSTREAM staging table refreshes first, with each refresh of its consumer
        stg_action = "INCREMENTAL" if first or n % 6 == 0 else "NO_DATA"
        _refresh(c, STG[0], STG[1], db, schema, wh_name, t, rng.uniform(5, 12) if stg_action != "NO_DATA" else 1.0,
                 stg_action, "CREATION" if first else "SCHEDULED", None, "RISK_ADMIN", raw_obj, rng)
        if stg_action != "NO_DATA":
            last_stg = t
        start = t + dt.timedelta(seconds=rng.uniform(8, 20))
        _refresh(c, tid, name, db, schema, wh_name, start, rng.uniform(15, 45), "INCREMENTAL",
                 "CREATION" if first else "SCHEDULED", lag, "RISK_ADMIN", stg_obj, rng)
        last = start
        n += 1
        t += dt.timedelta(seconds=rng.uniform(330, 540))
    _dt_rows(c, STG[0], STG[1], db, schema, wh_name, None, created, "RISK_ADMIN", data_ts=last_stg)
    _dt_rows(c, tid, name, db, schema, wh_name, lag, created, "RISK_ADMIN", data_ts=last)


def _dt_orphans(c, rng) -> None:
    b = c.b
    for tid, name, team, wh, days in ORPHANS:
        db = f"{team}_PROD_DB"
        created = b.ts(days, 3, 30)                     # in the ETL warehouse's busy hours
        src = c.old_tables(db, "STAGING")
        from tests.fake_snowflake.demo_pipelines import _obj
        src_obj = [_obj(f"{db}.STAGING.{src[0]['name']}", src[0]["id"])] if src else []
        _refresh(c, tid, name, db, "MARTS", wh, created, rng.uniform(60, 200), "INCREMENTAL", "CREATION", None,
                 f"{team}_ADMIN", src_obj, rng)
        _dt_rows(c, tid, name, db, "MARTS", wh, None, created, f"{team}_ADMIN", data_ts=created)


def _task_delays(c, rng) -> None:
    """Late starts on three tasks: queued behind other work, a late scheduler, a resume."""
    th = [r for r in c.b.w.rows[("account_usage", "TASK_HISTORY")]
          if r["name"] in (QUEUED[0], SCHED_LAG[0], RESUME[0]) and r["scheduled_from"] == "SCHEDULE"
          and r["attempt_number"] == 1 and r["state"] == "SUCCEEDED" and r.get("query_start_time")]
    by_q = {r["query_id"]: r for r in th if r.get("query_id")}
    qh = {}
    for q in c.b.w.rows[("account_usage", "QUERY_HISTORY")]:
        if q["query_id"] in by_q:
            qh[q["query_id"]] = q
    graphs = {(g["root_task_name"], g["run_id"], g["attempt_number"]): g
              for g in c.b.w.rows[("account_usage", "COMPLETE_TASK_GRAPHS")]
              if g["root_task_name"] in (QUEUED[0], SCHED_LAG[0], RESUME[0])}
    for r in sorted(th, key=lambda x: (x["name"], x["scheduled_time"])):
        q = qh.get(r["query_id"])
        g = graphs.get((r["name"], r["run_id"], r["attempt_number"]))
        if r["name"] == SCHED_LAG[0]:
            lag = dt.timedelta(seconds=rng.uniform(SCHED_LAG[1], SCHED_LAG[2]) if rng.random() < 0.7 else rng.uniform(1, 20))
            r["query_start_time"] += lag
            r["completed_time"] += lag
            if g is not None:
                g["query_start_time"] += lag
                g["completed_time"] += lag
        elif q is not None:
            lo, hi = (QUEUED[1], QUEUED[2]) if r["name"] == QUEUED[0] else (RESUME[1], RESUME[2])
            ms = int(rng.uniform(lo, hi) * 1000) if r["name"] == RESUME[0] or rng.random() < 0.85 else int(rng.uniform(5, 60) * 1000)
            col = "queued_overload_time" if r["name"] == QUEUED[0] else "queued_provisioning_time"
            q[col] = ms
            q["total_elapsed_time"] += ms
            q["end_time"] += dt.timedelta(milliseconds=ms)
            r["completed_time"] += dt.timedelta(milliseconds=ms)
            if g is not None:
                g["completed_time"] += dt.timedelta(milliseconds=ms)


def _show_pipes(c) -> None:
    """SHOW PIPES for every live demo pipe, from its ACCOUNT_USAGE.PIPES row."""
    for p in c.b.w.rows[("account_usage", "PIPES")]:
        if p.get("deleted") is not None:
            continue
        auto = p.get("is_autoingest_enabled") == "YES"
        c.b.show("pipes", created_on=p["created"], name=p["pipe_name"], database_name=p["pipe_catalog"],
                 schema_name=p["pipe_schema"], owner=p["pipe_owner"],
                 notification_channel=p.get("notification_channel_name") if auto else None, comment="",
                 integration=None, pattern=p.get("pattern"), error_integration=ERROR_INTEGRATIONS.get(p["pipe_name"]),
                 owner_role_type="ROLE", invalid_reason=INVALID.get(p["pipe_name"]), kind="STAGE")


def _copies(c, rng) -> None:
    b = c.b
    # every few minutes: a few MB from the landing folder, on the always-on ad hoc warehouse
    wh, user, team, days, every = FREQUENT_COPY
    db = f"{team}_PROD_DB"
    tgt = (c.old_tables(db, "RAW") or [None])[0]
    stage = f"s3://demo-landing-{team.lower()}/events/"
    for k in range(days, 0, -1):
        t = b.ts(k, 0, rng.randint(0, 4))
        end = t + dt.timedelta(days=1)
        while t < end:
            size = int(rng.uniform(1.5, 5) * MB)
            _copy(c, wh, user, t, rng.uniform(12, 30), size, rng.uniform(0.2, 0.8), team, "RAW", "hp-landing-copy", rng)
            if tgt:
                rows = size // 300
                b.au("COPY_HISTORY", file_name=f"events/{t:%Y/%m/%d/%H%M}/batch.json.gz", stage_location=stage,
                     last_load_time=t + dt.timedelta(seconds=20), row_count=rows, row_parsed=rows, file_size=size,
                     first_error_message=None, first_error_line_number=None, first_error_column_name=None,
                     error_count=0, error_limit=1, status="Loaded", table_id=tgt["id"], table_name=tgt["name"],
                     table_schema_id=c.schema_id.get((db, "RAW")), table_schema_name="RAW",
                     table_catalog_id=c.db_id[db], table_catalog_name=db, bytes_billed=size)
            t += dt.timedelta(seconds=every + rng.randint(-20, 20))
    # each team's 02:10 bulk COPY of its three daily export files (the files are in COPY_HISTORY already)
    for tm in c.cat["teams"]:
        if not c.old_tables(f"{tm}_PROD_DB", "STAGING"):
            continue
        wide = tm == WIDE_PREFIX
        for k in range(1, 96):
            t = b.ts(k, 2, 10)
            size = int(rng.uniform(250, 700) * MB)
            list_s = rng.uniform(240, 430) if wide else rng.uniform(1, 6)
            _copy(c, f"WH_{tm}_ETL", f"SVC_{tm}_INGEST", t, rng.uniform(60, 180), size, list_s, tm, "STAGING",
                  f"hp-daily-copy-{tm.lower()}", rng, cs=rng.uniform(0.02, 0.04) if wide else None)


def _copy(c, wh, user, start, secs, size, list_s, team, schema, qhash, rng, cs=None) -> None:
    """One COPY statement: listing runs before it executes, in the cloud services layer."""
    qid = c.qid("c")
    c.stmt(qid, wh, start, secs, "COPY", f"{team}_ADMIN", f"{team}_PROD_DB", schema, user=user, hkey=qhash)
    q = c.b.w.rows[("account_usage", "QUERY_HISTORY")][-1]
    list_ms = int(list_s * 1000)
    q.update(bytes_scanned=size, rows_inserted=size // 300,
             rows_produced=size // 300, list_external_files_time=list_ms, compilation_time=q["compilation_time"] + list_ms,
             total_elapsed_time=q["total_elapsed_time"] + list_ms, end_time=q["end_time"] + dt.timedelta(milliseconds=list_ms))
    if cs is not None:
        q["credits_used_cloud_services"] = cs
