"""Demo warehouse fit: what keeps warehouses awake, short runs, Snowpark-optimized and Gen2 fit, mixed workloads.

Called last from demo_compute.add, with its own random stream, so nothing before it draws different numbers.
- WH_STREAMLIT_APPS: an app deployed 35 days ago pings it every 4 minutes, day and night, so it never suspends;
  the hours it is kept up are billed as idle (demo_billing keeps them: IDLE_KEEP).
- WH_DBT_CI: CI jobs resume it, run a few seconds and suspend it from the script, so most runs bill the
  60-second minimum; the top-ups are billed as idle.
- WH_DS_FEATURES: a nightly plain-SQL feature build runs on the Snowpark-optimized warehouse.
- WH_SANDBOX_GEN2: a nightly merge job that runs about a third faster after the move to Gen2.
- WH_RISK_BI: a weekday afternoon merge job on the BI warehouse; people's queries queue while it runs.
"""
from __future__ import annotations

import datetime as dt
import random

from tests.fake_snowflake import data, demo_entities

POLL = ("WH_STREAMLIT_APPS", "SVC_PRODUCT_REPORTING", 35, 240)     # warehouse, user, days back it began, every s
CI = ("WH_DBT_CI", "SVC_PLATFORM_INGEST", 45, range(7, 20), (36, 48))  # warehouse, user, days, hours, minutes
FEATURES = ("WH_DS_FEATURES", "SVC_DATA_SCIENCE_INGEST", 32, 34)    # warehouse, user, days, statements a night
GEN2_JOB = ("WH_SANDBOX_GEN2", "SVC_PRODUCT_INGEST", 10, 0.68)      # warehouse, user, statements, speed after
MIXED = ("WH_RISK_BI", "SVC_RISK_INGEST", 35, 13, 80)               # warehouse, writer, days, start hour, minutes
HOUR = dt.timedelta(hours=1)


def add(b, whs: dict, query, ev, alive, users_on, gen2_at: int) -> None:
    rng = random.Random(f"{demo_entities.DEMO_SEED}:wh-fit")
    _idx.clear()
    _polls(b, whs, query, rng)
    _ci_runs(b, whs, query, ev, alive, rng)
    _feature_build(b, whs, query, rng)
    _gen2_job(b, whs, query, alive, rng, gen2_at)
    _mixed(b, whs, query, alive, users_on, rng)


_idx: dict = {}                           # (warehouse id, hour) -> (WAREHOUSE_METERING_HISTORY row, METERING_HISTORY row)


def _bill(b, w, hour: dt.datetime, compute: float | None = None, add: float = 0.0) -> None:
    """Raise one warehouse hour's billed compute (to `compute`, or by `add`); a missing hour is created."""
    rows = b.w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]
    mh = b.w.rows[("account_usage", "METERING_HISTORY")]
    if not _idx:
        m_by = {(x.get("entity_id"), x["start_time"]): x for x in mh if x["service_type"] == "WAREHOUSE_METERING"}
        for x in rows:
            _idx[(x["warehouse_id"], x["start_time"])] = (x, m_by.get((x["warehouse_id"], x["start_time"])))
    key = (w["id"], hour)
    if key not in _idx:
        r = dict(start_time=hour, end_time=hour + HOUR, warehouse_id=w["id"], warehouse_name=w["name"],
                 credits_used=0.0, credits_used_compute=0.0, credits_used_cloud_services=0.0,
                 credits_attributed_compute_queries=0.0)
        m = dict(service_type="WAREHOUSE_METERING", start_time=hour, end_time=hour + HOUR, entity_id=w["id"],
                 entity_type="WAREHOUSE", name=w["name"], credits_used_compute=0.0, credits_used_cloud_services=0.0,
                 credits_used=0.0)
        rows.append(r)
        mh.append(m)
        _idx[key] = (r, m)
    r, m = _idx[key]
    new = max(r["credits_used_compute"], compute) if compute is not None else r["credits_used_compute"] + add
    extra = new - r["credits_used_compute"]
    for t in (r, m):
        if t is not None:
            t["credits_used_compute"] += extra
            t["credits_used"] += extra


def _polls(b, whs, query, rng) -> None:
    """A health check from a Streamlit app every few minutes, around the clock: the warehouse never suspends."""
    name, user, days, every = POLL
    w = whs.get(name)
    if not w:
        return
    rate = data.RATE[w["size"]]
    for k in range(days, 0, -1):
        t = b.ts(k, 0, rng.randint(0, 3))
        end = t + dt.timedelta(days=1)
        while t < end:
            query(b, w, user, t, int(rng.uniform(120, 450)), int(rng.uniform(2e3, 4e4)), "MARTS", "streamlit:health",
                  query_hash="hcpoll", query_parameterized_hash="hcpoll", percentage_scanned_from_cache=1.0)
            t += dt.timedelta(seconds=every + rng.randint(-10, 10))
        for h in range(24):                              # up every hour of the day: billed in full
            _bill(b, w, b.ts(k, h), compute=float(rate))


def _ci_runs(b, whs, query, ev, alive, rng) -> None:
    """CI jobs: resume, a few seconds of dbt tests, then the script suspends the warehouse."""
    name, user, days, hours, minutes = CI
    w = whs.get(name)
    if not w:
        return
    rate = data.RATE[w["size"]]
    for k in range(days, 0, -1):
        if not alive(b, w, k) or b.back(k).weekday() >= 5:
            continue
        for h in hours:
            for mnt in minutes:
                if rng.random() < 0.15:
                    continue                             # no commit in this slot
                t = b.ts(k, h, mnt, rng.randint(0, 50))
                run = rng.uniform(8, 50)
                ev(b, w, t, "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", user, "PLATFORM_WRITE", state="STARTED")
                ev(b, w, t + dt.timedelta(seconds=1), "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", user,
                   "PLATFORM_WRITE")
                ev(b, w, t, "RESUME_CLUSTER", "WAREHOUSE_AUTORESUME", user, "PLATFORM_WRITE", cluster=1,
                   state="STARTED")
                q0 = t + dt.timedelta(seconds=2)
                n = rng.randint(1, 2)
                for i in range(n):                       # the tests fit inside the run
                    ms = int((run - 4) / n * rng.uniform(0.7, 0.95) * 1000)
                    query(b, w, user, q0, ms, int(rng.uniform(1e6, 2e8)), "STAGING", "dbt:ci:test",
                          query_hash=f"hcci{i}", query_parameterized_hash=f"hcci{i}")
                    q0 += dt.timedelta(milliseconds=(run - 4) / n * 1000)
                stop = t + dt.timedelta(seconds=run)
                ev(b, w, stop, "SUSPEND_WAREHOUSE", "WAREHOUSE_SUSPEND", user, "PLATFORM_WRITE", state="STARTED")
                ev(b, w, stop + dt.timedelta(seconds=1), "SUSPEND_WAREHOUSE", "WAREHOUSE_SUSPEND", user,
                   "PLATFORM_WRITE")
                ev(b, w, stop, "SUSPEND_CLUSTER", "WAREHOUSE_SUSPEND", user, "PLATFORM_WRITE", cluster=1,
                   state="STARTED")
                _bill(b, w, b.ts(k, h), add=(60 - run) / 3600 * rate)   # the 60-second minimum


def _feature_build(b, whs, query, rng) -> None:
    """A nightly SQL feature build, back to back, on the Snowpark-optimized warehouse: no procedure, no spill."""
    name, user, days, n = FEATURES
    w = whs.get(name)
    if not w:
        return
    kinds = ["INSERT", "MERGE", "CREATE_TABLE_AS_SELECT", "SELECT"]
    for k in range(days, 0, -1):
        t = b.ts(k, 1, rng.randint(0, 5))
        for i in range(n):
            ms = int(rng.uniform(150, 330) * 1000)
            scanned = int(rng.uniform(5e9, 6e10))
            query(b, w, user, t, ms, scanned, "STAGING", "dbt:features:nightly", query_type=kinds[i % 4],
                  query_hash=f"hcfb{i}", query_parameterized_hash=f"hcfb{i}", rows_inserted=int(rng.uniform(1e5, 5e7)),
                  bytes_written=int(scanned * 0.2))
            t += dt.timedelta(milliseconds=ms + 500)


def _gen2_job(b, whs, query, alive, rng, gen2_at: int) -> None:
    """A nightly merge job on the Gen2 sandbox; the same statements run faster after the move to Gen2."""
    name, user, n, speed = GEN2_JOB
    w = whs.get(name)
    if not w:
        return
    base = [rng.uniform(60, 180) for _ in range(n)]
    kinds = ["MERGE", "UPDATE", "MERGE", "DELETE", "MERGE"]
    for k in range(40, 0, -1):
        if not alive(b, w, k):
            continue
        t = b.ts(k, 2, rng.randint(0, 9))
        f = speed if k < gen2_at else 1.0
        for i in range(n):
            ms = int(base[i] * f * rng.uniform(0.9, 1.1) * 1000)
            query(b, w, user, t, ms, int(rng.uniform(2e9, 2e10)), "STAGING", "dbt:sandbox:merge", query_type=kinds[i % 5],
                  query_hash=f"hcg2{i}", query_parameterized_hash=f"hcg2{i}", rows_updated=int(rng.uniform(1e4, 1e6)))
            t += dt.timedelta(milliseconds=ms + 400)


def _mixed(b, whs, query, alive, users_on, rng) -> None:
    """A weekday afternoon merge on the BI warehouse; the people's dashboards queue behind it."""
    name, writer, days, hour, minutes = MIXED
    w = whs.get(name)
    if not w:
        return
    loads = {r["start_time"]: r for r in b.w.rows.get(("account_usage", "WAREHOUSE_LOAD_HISTORY"), [])
             if r["warehouse_id"] == w["id"]}
    for k in range(days, 0, -1):
        if not alive(b, w, k) or b.back(k).weekday() >= 5:
            continue
        start = b.ts(k, hour, rng.randint(0, 4))
        end = start + dt.timedelta(minutes=minutes)
        t = start
        while t < end:
            ms = int(rng.uniform(6, 14) * 60_000)
            scanned = int(rng.uniform(1e11, 5e11))
            query(b, w, writer, t, ms, scanned, "STAGING", "airflow:dag_risk_positions", query_type="MERGE",
                  query_hash="hcmx", query_parameterized_hash="hcmx", rows_updated=int(rng.uniform(1e6, 2e7)),
                  bytes_written=int(scanned * 0.1), query_load_percent=100)
            t += dt.timedelta(milliseconds=ms + 2000)
        people = users_on(b, w["team"], k)
        for _ in range(rng.randint(30, 45) if people else 0):
            s = start + dt.timedelta(seconds=rng.randint(0, minutes * 60))
            queued = int(rng.uniform(15_000, 120_000)) if rng.random() < 0.45 else 0
            query(b, w, rng.choice(people), s, int(rng.uniform(800, 25_000)), int(rng.uniform(1e8, 4e9)), "MARTS",
                  f"bi:tableau:{w['team'].lower()}_dash", queued_overload_time=queued)
            if queued:                                   # the wait is part of its elapsed time
                row = b.w.rows[("account_usage", "QUERY_HISTORY")][-1]
                row["total_elapsed_time"] += queued
                row["end_time"] += dt.timedelta(milliseconds=queued)
        m = 0
        while m < minutes:                               # running flat out, with queries waiting
            s = b.ts(k, hour) + dt.timedelta(minutes=m)
            row = loads.get(s)
            vals = dict(avg_running=round(rng.uniform(0.9, 1.0), 3), avg_queued_load=round(rng.uniform(0.3, 1.2), 3))
            if row:
                row.update(vals)
            else:
                b.au("WAREHOUSE_LOAD_HISTORY", start_time=s, end_time=s + dt.timedelta(minutes=5), warehouse_id=w["id"],
                     warehouse_name=name, avg_queued_provisioning=0.0, avg_blocked=0.0, **vals)
            m += 5
