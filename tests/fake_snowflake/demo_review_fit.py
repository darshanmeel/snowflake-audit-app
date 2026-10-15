"""Demo review fit: the edge cases a real account has that the other layers leave out.

Called last from demo_platform.add, with its own random stream, so nothing before it draws different numbers.
Compute:
- WH_PRODUCT_ETL moved to Gen2 15 days ago; the same work runs no faster, so each query costs 35% more.
- WH_MARKETING_ETL tried Gen2 for two weeks and went back to Gen1.
- WH_PLATFORM_ETL: a nightly reconciliation of point lookups moved onto it a week ago (oversized), and a
  freshness check resumes it three times a day for a few seconds, then the script suspends it (short runs).
- WH_PLATFORM_BI: its second cluster now and then starts and stops within a minute.
- WH_OPS_ETL: its long merges spill to local disk (undersized by spill time, not by remote spill).
- WH_RISK_ADHOC: analysts' big scans could use query acceleration; WH_TEMP_MIGRATION (dropped) had some too,
  and billed query acceleration before it was dropped.
- WH_PRODUCT_BI queues on weekday mornings (Economy scaling); WH_DATA_SCIENCE_BI was set to two clusters minimum.
- WH_OPS_ADHOC has auto-resume off; WH_PRODUCT_ADHOC's auto-suspend was raised to two hours.
- WH_DS_FEATURES' statements from before its Snowpark-optimized conversion ran on a standard warehouse.
- WH_FINANCE_ETL started a Gen2 test two days ago (too soon to judge); WH_DS_SCRATCH, Snowpark-optimized, is
  resumed by hand now and then but runs nothing.
- WH_FINANCE_BI: a finance health check polls it for an hour every morning, keeping it up.
- WH_PRODUCT_LIVE: an interactive warehouse created this week with a 90 s auto-suspend; WH_SALES_DEV's is 30 s.
- WH_OPS_ETL: one day's metering came without the per-query split.
Storage:
- a Fail-safe copy with no names that still reads deleted = FALSE, and a transient copy dropped with 1 GB left;
- ARCHIVE_DB.SNAPSHOTS_2024: a 5 TB snapshot nobody reads or writes; FEATURE_STORE_DB.NEW_WORK, created days ago;
- an old, rewritten 2.3 TB clone nobody reads, and a clone whose source is not in TABLE_STORAGE_METRICS at all;
- a staging table with storage metrics but no TABLES row; a database created yesterday; one that started empty;
- an Iceberg table too new for TABLES (read by name), an external-catalog Iceberg table not refreshed in 20 days,
  an external table whose auto-refresh stopped 12 days ago, search optimization billed on a table since dropped;
- another org account opened four days ago (one settled day of storage); FAKE_EU also holds hybrid tables;
- PRODUCT_PROD_DB.MARTS: a 2 TB events table with no key that dashboards scan end to end, and a clustered
  orders table that pays off (pruning history has no rows for it yet);
- a backup set not listed in BACKUP_SETS, and the deleted set still holding half a terabyte;
- a materialized view that refreshed until it was dropped; a Time Travel-heavy table with no TABLES row;
- a scratch table loaded by MERGEs that read only itself; FEATURE_STORE_DB.OLD_EXPERIMENTS, 25 tables
  mostly unread; a lifecycle policy whose runs stopped, and one attached that never ran;
- the account's stage total holds every stage the per-stage view lists (the test stages were left out);
- SHOW PARAMETERS lists the rest of the account parameters, at Snowflake's defaults.
"""
from __future__ import annotations

import datetime as dt
import math
import random

from tests.fake_snowflake import data, demo_billing, demo_compute, demo_entities, demo_storage

HOUR = dt.timedelta(hours=1)
GB = 1024 ** 3
TB = 1024 ** 4
GEN2_COST = 1.35                          # Gen2 hourly rate against Gen1 (not Azure)
GEN2_MOVE = ("WH_PRODUCT_ETL", 15)        # warehouse, days back it moved to Gen2 for good
GEN2_TRIAL = ("WH_MARKETING_ETL", 28, 12)  # warehouse, days back it moved to Gen2, days back it moved back
FRESHNESS = ("WH_PLATFORM_ETL", "SVC_PLATFORM_INGEST", 40, ((4, 40), (12, 40), (20, 40)))
RECON = ("WH_PLATFORM_ETL", "SVC_PLATFORM_INGEST", 7, 0.975)   # warehouse, user, nights, small share to reach


def add(b) -> None:
    rng = random.Random(f"{demo_entities.DEMO_SEED}:review_fit")
    c = _C(b, rng)
    c.gen2(*GEN2_MOVE[:2], None)
    c.gen2(*GEN2_TRIAL)
    c.freshness_runs()
    c.cluster_blips()
    c.recon_lookups()
    c.spill_time()
    c.qas()
    c.multicluster()
    c.snowpark_history()
    c.gen2("WH_FINANCE_ETL", 2, None)
    c.snowpark_unused()
    c.keepalive_morning()
    c.config_edges()
    c.no_split_day()
    s = _S(b, rng)
    s.dropped_copies()
    s.schemas()
    s.clones()
    s.orphan_metrics()
    s.databases()
    s.iceberg_external()
    s.search_optimization_dropped()
    s.org_new_account()
    s.org_hybrid()
    s.clustering(c)
    s.backups()
    s.mv_dropped()
    s.orphan_time_travel()
    s.self_merge(c)
    s.sprawl()
    s.lifecycle()
    s.stage_totals()
    s.account_parameters()


class _C:
    def __init__(self, b, rng):
        self.b, self.rng, self.w = b, rng, b.w
        self.whs = {w["name"]: w for w in b.w.wh if "like" in w}
        self.show = {r["name"]: r for r in b.w.rows.get(("show", "warehouses"), [])}
        self._idx: dict = {}

    def _rows(self, view):
        return self.w.rows.setdefault(("account_usage", view), [])

    def _index(self) -> dict:
        if not self._idx:
            mh = {(x.get("entity_id"), x["start_time"]): x for x in self._rows("METERING_HISTORY")
                  if x["service_type"] == "WAREHOUSE_METERING"}
            for x in self._rows("WAREHOUSE_METERING_HISTORY"):
                self._idx[(x["warehouse_id"], x["start_time"])] = (x, mh.get((x["warehouse_id"], x["start_time"])))
        return self._idx

    def bill(self, w, hour: dt.datetime, add: float) -> None:
        """Add compute to one warehouse hour, in both metering views; a missing hour is created."""
        self._index()
        key = (w["id"], hour)
        if key not in self._idx:
            r = dict(start_time=hour, end_time=hour + HOUR, warehouse_id=w["id"], warehouse_name=w["name"],
                     credits_used=0.0, credits_used_compute=0.0, credits_used_cloud_services=0.0,
                     credits_attributed_compute_queries=0.0)
            m = dict(service_type="WAREHOUSE_METERING", start_time=hour, end_time=hour + HOUR, entity_id=w["id"],
                     entity_type="WAREHOUSE", name=w["name"], credits_used_compute=0.0,
                     credits_used_cloud_services=0.0, credits_used=0.0)
            self._rows("WAREHOUSE_METERING_HISTORY").append(r)
            self._rows("METERING_HISTORY").append(m)
            self._idx[key] = (r, m)
        for t in self._idx[key]:
            if t is not None:
                t["credits_used_compute"] += add
                t["credits_used"] += add

    def billed(self, w, hour: dt.datetime) -> bool:
        return (w["id"], hour) in self._index()

    # ---- Gen2 -------------------------------------------------------------------------------------------------
    def gen2(self, name: str, start_k: int, end_k: int | None) -> None:
        """Gen2 from start_k days back (to end_k, or still): the hours bill 1.35 times, the queries run as before."""
        w = self.whs.get(name)
        if not w:
            return
        b = self.b
        start = b.ts(start_k, 10)
        end = b.ts(end_k, 10) if end_k else None
        demo_compute._convert(b, w, start, "CONVERT_RESOURCE_CONSTRAINT", w["team"], "STANDARD_GEN_2")
        if end:
            demo_compute._convert(b, w, end, "CONVERT_RESOURCE_CONSTRAINT", w["team"], "STANDARD_GEN_1")
        else:
            row = self.show.get(name)
            if row:
                row.update(resource_constraint="STANDARD_GEN_2", generation="2")

        def inside(t):
            return t >= start and (end is None or t < end)

        for r in self._rows("WAREHOUSE_EVENTS_HISTORY"):
            if r["warehouse_id"] == w["id"] and r["event_name"] == "WAREHOUSE_CONSISTENT" and inside(r["timestamp"]):
                r["resource_constraint"] = "STANDARD_GEN_2"
        mh = {(x.get("entity_id"), x["start_time"]): x for x in self._rows("METERING_HISTORY")
              if x["service_type"] == "WAREHOUSE_METERING" and x.get("entity_id") == w["id"]}
        for r in self._rows("WAREHOUSE_METERING_HISTORY"):
            if r["warehouse_id"] != w["id"] or not inside(r["start_time"]):
                continue
            for t in (r, mh.get((w["id"], r["start_time"]))):
                if t is None:
                    continue
                extra = t["credits_used_compute"] * (GEN2_COST - 1)
                t["credits_used_compute"] += extra
                t["credits_used"] += extra
            if r.get("credits_attributed_compute_queries") is not None:
                r["credits_attributed_compute_queries"] *= GEN2_COST
        # attribution at the Gen2 rate, so demo_billing keeps it rather than pricing these runs at Gen1
        qah = self._rows("QUERY_ATTRIBUTION_HISTORY")
        have = {r["query_id"] for r in qah}
        for q in self._rows("QUERY_HISTORY"):
            if (q.get("warehouse_id") != w["id"] or not inside(q["start_time"]) or q["query_id"] in have
                    or q["query_type"] in demo_billing.META or (q.get("execution_time") or 0) < 100):
                continue
            size = q.get("warehouse_size") or self.w.size_at(w, q["start_time"])
            qah.append(dict(query_id=q["query_id"], parent_query_id=None, root_query_id=q["query_id"],
                            warehouse_id=w["id"], warehouse_name=w["name"], query_hash=q.get("query_hash"),
                            query_parameterized_hash=q.get("query_parameterized_hash"), query_tag=q.get("query_tag"),
                            user_name=q["user_name"], start_time=q["start_time"], end_time=q["end_time"],
                            credits_attributed_compute=q["execution_time"] / 3_600_000 * data.RATE[size] * GEN2_COST,
                            credits_used_query_acceleration=None))

    # ---- short runs -------------------------------------------------------------------------------------------
    def freshness_runs(self) -> None:
        """A source-freshness check resumes the 3X-Large ETL warehouse, runs a few seconds, and the script suspends it."""
        name, user, days, slots = FRESHNESS
        w = self.whs.get(name)
        if not w:
            return
        b, rng = self.b, self.rng
        rate = data.RATE[w["size"]]
        for k in range(days, 0, -1):
            for h, m in slots:
                hour = b.ts(k, h)
                if self.billed(w, hour) or self.billed(w, hour - HOUR):
                    continue                             # the warehouse was up anyway: no separate run
                t = b.ts(k, h, m, rng.randint(0, 50))
                run = rng.uniform(14, 28)
                ev = demo_compute._ev
                ev(b, w, t, "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", user, "PLATFORM_WRITE", state="STARTED")
                ev(b, w, t + dt.timedelta(seconds=1), "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", user, "PLATFORM_WRITE")
                ev(b, w, t, "RESUME_CLUSTER", "WAREHOUSE_AUTORESUME", user, "PLATFORM_WRITE", cluster=1, state="STARTED")
                demo_compute._query(b, w, user, t + dt.timedelta(seconds=2), int(rng.uniform(4000, 9000)),
                                    int(rng.uniform(1e6, 5e7)), "STAGING", "dbt:source_freshness",
                                    query_hash="hcfresh", query_parameterized_hash="hcfresh")
                stop = t + dt.timedelta(seconds=run)
                ev(b, w, stop, "SUSPEND_WAREHOUSE", "WAREHOUSE_SUSPEND", user, "PLATFORM_WRITE", state="STARTED")
                ev(b, w, stop + dt.timedelta(seconds=1), "SUSPEND_WAREHOUSE", "WAREHOUSE_SUSPEND", user,
                   "PLATFORM_WRITE")
                ev(b, w, stop, "SUSPEND_CLUSTER", "WAREHOUSE_SUSPEND", user, "PLATFORM_WRITE", cluster=1,
                   state="STARTED")
                self.bill(w, hour, 60 / 3600 * rate)    # a resume bills a full minute

    def cluster_blips(self) -> None:
        """Cluster 2 of WH_PLATFORM_BI starts for a burst and stops again inside a minute, some weekdays."""
        w = self.whs.get("WH_PLATFORM_BI")
        if not w or w["max"] < 2:
            return
        b, rng = self.b, self.rng
        for k in range(40, 0, -1):
            if b.back(k).weekday() >= 5 or rng.random() < 0.4:
                continue
            start = b.ts(k, 10, rng.randint(0, 50), rng.randint(0, 59))
            demo_compute._spin(b, w, start, start + dt.timedelta(seconds=rng.randint(20, 45)), 2)
            self.bill(w, b.ts(k, 10), 60 / 3600 * data.RATE[w["size"]])

    # ---- oversized: point lookups on the biggest warehouse ------------------------------------------------------
    def recon_lookups(self) -> None:
        name, user, nights, share = RECON
        w = self.whs.get(name)
        if not w:
            return
        b, rng = self.b, self.rng
        lo = b.ts(nights, 0)
        total = small = 0
        for q in self._rows("QUERY_HISTORY"):
            if (q.get("warehouse_id") == w["id"] and q["start_time"] >= lo and q["execution_status"] == "SUCCESS"
                    and (q.get("execution_time") or 0) > 0):
                total += 1
                spill = (q.get("bytes_spilled_to_local_storage") or 0) + (q.get("bytes_spilled_to_remote_storage") or 0)
                small += (q.get("bytes_scanned") or 0) < GB and q["execution_time"] < 10_000 and spill == 0
        need = max(0, math.ceil((share * total - small) / (1 - share)))
        per_night = math.ceil(need / nights) + 10
        for k in range(nights, 0, -1):
            t = b.ts(k, 2, 5)
            demo_compute._ev(b, w, t - dt.timedelta(seconds=1), "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", "SYSTEM",
                             state="STARTED")
            for _ in range(per_night):
                ms = int(rng.uniform(1200, 4000))
                demo_compute._query(b, w, user, t, ms, int(rng.uniform(1e6, 6e8)), "STAGING", "airflow:dag_recon_lookups",
                                    query_hash="hcrecon", query_parameterized_hash="hcrecon",
                                    rows_produced=int(rng.uniform(1, 40)))
                t += dt.timedelta(milliseconds=ms + 300)
            demo_compute._ev(b, w, t + dt.timedelta(seconds=60), "SUSPEND_WAREHOUSE", "WAREHOUSE_AUTOSUSPEND",
                             "SYSTEM", state="STARTED")

    # ---- undersized by spill time -------------------------------------------------------------------------------
    def spill_time(self) -> None:
        w = self.whs.get("WH_OPS_ETL")
        if not w:
            return
        lo = self.b.ts(95, 0)
        qs = [q for q in self._rows("QUERY_HISTORY") if q.get("warehouse_id") == w["id"] and q["start_time"] >= lo
              and (q.get("execution_time") or 0) > 0]
        total = sum(q["execution_time"] for q in qs)
        done = sum(q["execution_time"] for q in qs if (q.get("bytes_spilled_to_local_storage") or 0)
                   + (q.get("bytes_spilled_to_remote_storage") or 0) > 0)
        for q in sorted(qs, key=lambda q: -q["execution_time"]):
            if done >= 0.6 * total:
                break
            if (q.get("bytes_spilled_to_local_storage") or 0) + (q.get("bytes_spilled_to_remote_storage") or 0) > 0:
                continue
            q["bytes_spilled_to_local_storage"] = int(self.rng.uniform(2e9, 6e9))   # local disk only
            done += q["execution_time"]

    # ---- query acceleration -------------------------------------------------------------------------------------
    def _eligible(self, q, w, share: float, factor: int) -> None:
        self.b.au("QUERY_ACCELERATION_ELIGIBLE", query_id=q["query_id"], query_text=q["query_text"],
                  start_time=q["start_time"], end_time=q["end_time"], warehouse_name=w["name"],
                  warehouse_size=q["warehouse_size"], eligible_query_acceleration_time=q["execution_time"] / 1000 * share,
                  upper_limit_scale_factor=factor, query_hash=q["query_hash"], query_hash_version=2,
                  query_parameterized_hash=q["query_parameterized_hash"], query_parameterized_hash_version=1)

    def qas(self) -> None:
        b, rng = self.b, self.rng
        w = self.whs.get("WH_RISK_ADHOC")
        if w:                                            # big scans with a selective filter: most of it could be offloaded
            for k in range(95, 0, -1):
                if b.back(k).weekday() >= 5 or rng.random() < 0.4 or not demo_compute._alive(b, w, k):
                    continue
                users = demo_compute._users_on(b, w["team"], k)
                if not users:
                    continue
                demo_compute._query(b, w, rng.choice(users), b.ts(k, rng.randint(9, 16), rng.randint(0, 59)),
                                    int(rng.uniform(15, 30) * 60_000), int(rng.uniform(1e11, 4e11)), "MARTS",
                                    None, query_hash="hcrscan", query_parameterized_hash=f"hcrscan{rng.randint(0, 3)}")
                self._eligible(self._rows("QUERY_HISTORY")[-1], w, rng.uniform(0.75, 0.9),
                               rng.choice([2, 4, 4, 8, 16, 32]))
        w = self.whs.get("WH_TEMP_MIGRATION")
        if not w:
            return
        lo, hi = b.ts(40, 0), b.ts(w["dropped_days"] + 1, 0)
        long_q = [q for q in self._rows("QUERY_HISTORY") if q.get("warehouse_id") == w["id"]
                  and lo <= q["start_time"] < hi and (q.get("execution_time") or 0) > 60_000]
        for q in long_q[:10]:                            # the dropped warehouse: eligible, but nothing to tune now
            self._eligible(q, w, 0.5, 8)
        hours: dict = {}
        for q in long_q[10:50]:                          # and it billed acceleration before it went
            q["query_acceleration_bytes_scanned"] = int((q.get("bytes_scanned") or 0) * rng.uniform(0.3, 0.6))
            q["query_acceleration_partitions_scanned"] = int(rng.uniform(200, 3000))
            q["query_acceleration_upper_limit_scale_factor"] = 8
            h = q["start_time"].replace(minute=0, second=0, microsecond=0)
            hours[h] = hours.get(h, 0.0) + round(rng.uniform(0.3, 0.7), 4)
        for h, credits in sorted(hours.items()):
            b.au("QUERY_ACCELERATION_HISTORY", start_time=h, end_time=h + HOUR, credits_used=credits,
                 warehouse_id=w["id"], warehouse_name=w["name"])
            b.au("METERING_HISTORY", service_type="QUERY_ACCELERATION", start_time=h, end_time=h + HOUR,
                 entity_id=w["id"], entity_type="WAREHOUSE", name=w["name"], credits_used_compute=credits,
                 credits_used_cloud_services=0.0, credits_used=credits)

    # ---- multi-cluster and settings -----------------------------------------------------------------------------
    def multicluster(self) -> None:
        b, rng = self.b, self.rng
        w = self.whs.get("WH_PRODUCT_BI")
        if w:                                            # Economy waits before it adds a cluster: mornings queue
            loads = {r["start_time"]: r for r in self._rows("WAREHOUSE_LOAD_HISTORY") if r["warehouse_id"] == w["id"]}
            days = [k for k in range(1, 31) if b.back(k).weekday() < 5]
            for k in sorted(rng.sample(days, min(10, len(days)))):
                for m in range(0, 120, 5):
                    s = b.ts(k, 9) + dt.timedelta(minutes=m)
                    vals = dict(avg_queued_load=round(rng.uniform(0.5, 1.1), 3))
                    row = loads.get(s)
                    if row:
                        row["avg_running"] = max(row.get("avg_running") or 0.0, round(rng.uniform(1.5, 2.5), 3))
                        row.update(vals)
                    else:
                        b.au("WAREHOUSE_LOAD_HISTORY", start_time=s, end_time=s + dt.timedelta(minutes=5),
                             warehouse_id=w["id"], warehouse_name=w["name"], avg_running=round(rng.uniform(1.5, 2.5), 3),
                             avg_queued_provisioning=0.0, avg_blocked=0.0, **vals)
        self._alter("WH_DATA_SCIENCE_BI", 2, min_cluster_count=2)    # kept two clusters up after a launch
        self._alter("WH_OPS_ADHOC", 6, auto_resume="false")           # turned off while someone investigated
        self._alter("WH_PRODUCT_ADHOC", None, auto_suspend=7200)      # the ALTER 55 days ago raised it to two hours

    def _alter(self, name: str, k: int | None, **settings) -> None:
        w, row = self.whs.get(name), self.show.get(name)
        if not w or not row:
            return
        row.update(settings)
        if k is not None:
            demo_compute._ev(self.b, w, self.b.ts(k, 16, 5), "ALTER_WAREHOUSE", None,
                             demo_compute._admin(self.b, w["team"]), f"{w['team']}_ADMIN")
            row["updated_on"] = self.b.ts(k, 16, 5)

    def snowpark_history(self) -> None:
        """Statements from before WH_DS_FEATURES became Snowpark-optimized ran on a standard warehouse."""
        w = self.whs.get("WH_DS_FEATURES")
        if not w:
            return
        at = self.b.ts(33, 15)
        for q in self._rows("QUERY_HISTORY"):
            if q.get("warehouse_id") == w["id"] and q["start_time"] < at:
                q["warehouse_type"] = "STANDARD"

    # ---- a Snowpark-optimized warehouse that runs nothing; a morning poll; settings edges ----------------------
    def snowpark_unused(self) -> None:
        """WH_DS_SCRATCH: resumed from the UI on some weekdays and suspended again, with no statement run."""
        tpl = self.show.get("WH_DS_FEATURES")
        if not tpl:
            return
        b, rng = self.b, self.rng
        w = dict(id=3039, name="WH_DS_SCRATCH", type="SNOWPARK-OPTIMIZED", team="DATA_SCIENCE")
        b.show("warehouses", **dict(tpl, name=w["name"], state="SUSPENDED", size="Small", started_clusters=0,
                                    auto_suspend=600, created_on=b.ts(60, 11), resumed_on=b.ts(2, 10),
                                    updated_on=b.ts(60, 11), resource_constraint="MEMORY_16X"))
        who = demo_compute._admin(b, w["team"])
        for k in range(58, 0, -1):
            if b.back(k).weekday() >= 5 or rng.random() < 0.5:
                continue
            t = b.ts(k, 10, rng.randint(0, 40))
            demo_compute._ev(b, w, t, "RESUME_WAREHOUSE", "WAREHOUSE_RESUME", who, "DATA_SCIENCE_WRITE")
            demo_compute._ev(b, w, t + dt.timedelta(minutes=15), "SUSPEND_WAREHOUSE", "WAREHOUSE_SUSPEND", who,
                             "DATA_SCIENCE_WRITE")
            self.bill(w, b.ts(k, 10), 0.25 * data.RATE["Small"] * 1.5)

    def keepalive_morning(self) -> None:
        """A finance health check polls WH_FINANCE_BI every 100 s from 06:00 to 07:00, before anyone works."""
        w = self.whs.get("WH_FINANCE_BI")
        if not w:
            return
        b, rng = self.b, self.rng
        rate = data.RATE[w["size"]]
        for k in range(40, 0, -1):
            t = b.ts(k, 6, 0, rng.randint(0, 20))
            while t < b.ts(k, 7):
                demo_compute._query(b, w, "SVC_FINANCE_REPORTING", t, int(rng.uniform(90, 220)), int(rng.uniform(1e3, 2e4)),
                                    "MARTS", "health:finance_freshness", query_hash="hcfinpoll",
                                    query_parameterized_hash="hcfinpoll", percentage_scanned_from_cache=1.0)
                t += dt.timedelta(seconds=100)
            self._index()
            r, _ = self._idx.get((w["id"], b.ts(k, 6)), (None, None))
            have = r["credits_used_compute"] if r else 0.0
            self.bill(w, b.ts(k, 6), max(0.0, rate - have))     # up the whole hour
            r, _ = self._idx[(w["id"], b.ts(k, 6))]
            r["credits_attributed_compute_queries"] = (r.get("credits_attributed_compute_queries") or 0.0) + 0.02

    def config_edges(self) -> None:
        tpl = self.show.get("WH_PRODUCT_BI")
        if tpl:                                          # created this week, nothing run on it yet
            b = self.b
            self.b.show("warehouses", **dict(tpl, name="WH_PRODUCT_LIVE", state="SUSPENDED", size="Small",
                                             min_cluster_count=1, max_cluster_count=1, started_clusters=0,
                                             auto_suspend=90, created_on=b.ts(3, 14),
                                             resumed_on=None, updated_on=b.ts(3, 14), enable_query_acceleration="false",
                                             query_acceleration_max_scale_factor=0, resource_constraint=None,
                                             generation=None))
        self._alter("WH_SALES_DEV", 12, auto_suspend=30)              # set to 30 s by hand

    def no_split_day(self) -> None:
        """One day of WH_OPS_ETL metering arrived without the per-query split."""
        w = self.whs.get("WH_OPS_ETL")
        if not w:
            return
        day = self.b.back(17)
        for r in self._rows("WAREHOUSE_METERING_HISTORY"):
            if r["warehouse_id"] == w["id"] and r["start_time"].date() == day:
                r["credits_attributed_compute_queries"] = None


class _S:
    def __init__(self, b, rng):
        self.b, self.rng, self.w = b, rng, b.w
        self.st = demo_storage._Store(b)
        self.st.rng = rng

    def table(self, tid, db, sch, name, owner, created, gb, typ="BASE TABLE", transient="NO", retention=1,
              deleted=None, altered=None, iceberg="NO", clustering_key=None) -> None:
        b = self.b
        self.st.au("TABLES", table_id=tid, table_name=name, table_schema_id=self.w.schema_id[(db, sch)],
                   table_schema=sch, table_catalog_id=self.w.dbs[db], table_catalog=db, table_owner=owner,
                   table_type=typ, is_transient=transient, clustering_key=clustering_key,
                   auto_clustering_on="YES" if clustering_key else "NO", row_count=int(gb * 4e6),
                   bytes=int(gb * GB), retention_time=retention, created=b.ts(created, 9),
                   last_altered=altered or b.ts(min(created, 2), 9), last_ddl=b.ts(created, 9), last_ddl_by=owner,
                   deleted=deleted, is_iceberg=iceberg, is_dynamic="NO", is_hybrid="NO")
        if deleted is not None and db != "LEGACY_DW_DB":
            return                                       # a dropped object's grants go with it
        self.st.grant("OWNERSHIP", "TABLE", f"{db}.{sch}.{name}", owner, schema_=sch, catalog=db,
                      deleted=deleted is not None)

    def tsm(self, tid, db, sch, name, created, active=0.0, tt=0.0, fs=0.0, clone_of=None, transient="NO",
            deleted=False, dropped=None, entered_fs=None, named=True) -> None:
        b = self.b
        self.st.au("TABLE_STORAGE_METRICS", id=tid, table_name=name if named else None,
                   table_schema_id=self.w.schema_id[(db, sch)], table_schema=sch if named else None,
                   table_catalog_id=self.w.dbs[db], table_catalog=db if named else None,
                   clone_group_id=clone_of or tid, is_transient=transient, active_bytes=int(active * GB),
                   time_travel_bytes=int(tt * GB), failsafe_bytes=int(fs * GB), retained_for_clone_bytes=0,
                   deleted=deleted, table_created=b.ts(created, 9), table_dropped=dropped,
                   table_entered_failsafe=entered_fs)

    def schema(self, sid, db, name, owner, created) -> None:
        self.w.schema_id[(db, name)] = sid
        self.st.au("SCHEMATA", schema_id=sid, schema_name=name, catalog_id=self.w.dbs[db], catalog_name=db,
                   schema_owner=owner, retention_time=1, is_transient="NO", is_managed_access="NO",
                   created=self.b.ts(created, 9), last_altered=self.b.ts(min(created, 3), 9), deleted=None,
                   owner_role_type="ROLE")
        self.st.grant("OWNERSHIP", "SCHEMA", f"{db}.{name}", owner, schema_=name, catalog=db)

    def reads(self, n, fqn, oid, ok) -> None:
        """ACCESS_HISTORY rows for demo SELECTs that have none yet."""
        b = self.b
        seen = {r["query_id"] for r in self.w.rows.get(("account_usage", "ACCESS_HISTORY"), [])}
        pool = [q for q in self.w.q_rows if q["query_id"] not in seen and q["execution_status"] == "SUCCESS"
                and q["query_type"] == "SELECT" and ok((b.as_of - q["start_time"].date()).days, q)]
        for q in self.rng.sample(pool, min(n, len(pool))):
            o = {"objectDomain": "Table", "objectName": fqn, "objectId": oid,
                 "columns": [{"columnId": 2001, "columnName": "ID"}]}
            self.st.au("ACCESS_HISTORY", query_id=q["query_id"], query_start_time=q["start_time"],
                       user_name=q["user_name"], direct_objects_accessed=[o], base_objects_accessed=[o],
                       objects_modified=[], policies_referenced=[], root_query_id=q["query_id"])

    # ---- dropped copies ---------------------------------------------------------------------------------------
    def dropped_copies(self) -> None:
        b = self.b
        # Fail-safe copy with no names that still reads deleted = FALSE and has no drop time
        self.tsm(46400, "CLICKSTREAM_DB", "STAGING", None, 120, fs=500, deleted=False,
                 entered_fs=b.ts(3, 9), named=False)
        self.st.extend("CLICKSTREAM_DB", 3, 500 * GB, db_col="average_failsafe_bytes", su_col="failsafe_bytes")
        # a transient work table dropped two days ago: exactly 1 GB of Time Travel left, no Fail-safe
        self.table(46401, "CLICKSTREAM_DB", "STAGING", "TMP_SESSION_KEYS", "PLATFORM_WRITE", 60, 1, transient="YES",
                   retention=1, deleted=b.ts(2, 9))
        self.tsm(46401, "CLICKSTREAM_DB", "STAGING", "TMP_SESSION_KEYS", 60, tt=1, transient="YES", deleted=True,
                 dropped=b.ts(2, 9))

    # ---- schemas: an old snapshot nobody uses, and a new one --------------------------------------------------
    def schemas(self) -> None:
        self.schema(4311, "ARCHIVE_DB", "SNAPSHOTS_2024", "FINANCE_ADMIN", 300)
        self.table(46402, "ARCHIVE_DB", "SNAPSHOTS_2024", "GL_SNAPSHOT_2024Q4", "FINANCE_ADMIN", 300, 5120,
                   retention=90, altered=self.b.ts(290, 9))
        self.tsm(46402, "ARCHIVE_DB", "SNAPSHOTS_2024", "GL_SNAPSHOT_2024Q4", 300, active=5120)
        self.st.extend("ARCHIVE_DB", 300, 5120 * GB)
        self.schema(4312, "FEATURE_STORE_DB", "NEW_WORK", "DATA_SCIENCE_ADMIN", 5)
        self.table(46403, "FEATURE_STORE_DB", "NEW_WORK", "WIP_EMBEDDINGS_V2", "DATA_SCIENCE_ADMIN", 5, 500,
                   retention=30)
        self.tsm(46403, "FEATURE_STORE_DB", "NEW_WORK", "WIP_EMBEDDINGS_V2", 5, active=500)
        self.st.extend("FEATURE_STORE_DB", 5, lambda k: 500 * GB * (6 - k) / 5)

    # ---- clones -----------------------------------------------------------------------------------------------
    def clones(self) -> None:
        b = self.b
        # a dev copy of USER_FEATURES_DAILY, rebuilt in full on the clone 190 days ago and never read since
        self.table(46404, "DATA_SCIENCE_DEV_DB", "SCRATCH", "USER_FEATURES_BACKFILL_TEST", "DATA_SCIENCE_WRITE",
                   200, 2300, altered=b.ts(190, 9))
        self.tsm(46404, "DATA_SCIENCE_DEV_DB", "SCRATCH", "USER_FEATURES_BACKFILL_TEST", 200, active=2300,
                 clone_of=46011)
        self.st.extend("DATA_SCIENCE_DEV_DB", 190, 2300 * GB)
        # a clone whose source is in no TABLE_STORAGE_METRICS row the role can see
        self.table(46405, "OPS_DEV_DB", "SCRATCH", "ORDERS_COPY_OLD", "OPS_WRITE", 120, 12, altered=b.ts(118, 9))
        self.tsm(46405, "OPS_DEV_DB", "SCRATCH", "ORDERS_COPY_OLD", 120, active=12, clone_of=46499)
        self.st.extend("OPS_DEV_DB", 120, 12 * GB)

    def orphan_metrics(self) -> None:
        """A staging table with storage metrics but no TABLES row (TABLES lags or the role cannot see it)."""
        self.tsm(46406, "CLICKSTREAM_DB", "STAGING", "STG_ORPHAN_LOAD", 150, active=200, tt=40, fs=1000)
        self.st.extend("CLICKSTREAM_DB", 150, 240 * GB)
        self.st.extend("CLICKSTREAM_DB", 150, 1000 * GB, db_col="average_failsafe_bytes", su_col="failsafe_bytes")

    # ---- databases: created yesterday, and one that started empty ---------------------------------------------
    def _database(self, dbid, name, team, created) -> None:
        b = self.b
        self.w.dbs[name] = dbid
        self.st.au("DATABASES", database_id=dbid, database_name=name, database_owner=f"{team}_ADMIN",
                   is_transient="NO", type="STANDARD", retention_time=1, created=b.ts(created, 8),
                   last_altered=b.ts(created, 8), deleted=None, owner_role_type="ROLE", object_visibility="PRIVILEGED")
        self.st.show("databases", created_on=b.ts(created, 8), name=name, is_default="N", is_current="N", origin="",
                     owner=f"{team}_ADMIN", comment="", options="", retention_time="1", kind="STANDARD",
                     owner_role_type="ROLE")
        self.st.grant("OWNERSHIP", "DATABASE", name, f"{team}_ADMIN")

    def databases(self) -> None:
        b = self.b
        su = {r["usage_date"]: r for r in self.w.rows.get(("account_usage", "STORAGE_USAGE"), [])}

        def day(dbid, name, k, nbytes):
            self.st.au("DATABASE_STORAGE_USAGE_HISTORY", usage_date=b.back(k), database_id=dbid, database_name=name,
                       deleted=None, average_database_bytes=nbytes, average_failsafe_bytes=0.0,
                       average_hybrid_table_storage_bytes=0.0, average_archive_storage_cool_bytes=0.0,
                       average_archive_storage_cold_bytes=0.0)
            if b.back(k) in su:
                su[b.back(k)]["storage_bytes"] += nbytes

        self._database(435, "NEW_LAKE_DB", "PLATFORM", 1)            # one day of history so far
        day(435, "NEW_LAKE_DB", 1, 500 * GB)
        self._database(436, "ML_SCRATCH_DB", "DATA_SCIENCE", 27)     # created empty, then loaded every day
        self.schema(4313, "ML_SCRATCH_DB", "PUBLIC", "DATA_SCIENCE_ADMIN", 27)
        self.table(46407, "ML_SCRATCH_DB", "PUBLIC", "TRAINING_FRAMES", "DATA_SCIENCE_ADMIN", 27, 1024,
                   altered=b.ts(1, 4))
        self.tsm(46407, "ML_SCRATCH_DB", "PUBLIC", "TRAINING_FRAMES", 27, active=1024)
        for k in range(27, 0, -1):
            day(436, "ML_SCRATCH_DB", k, 1024 * GB * (27 - k) / 26)
            if k < 27:
                start = b.ts(k, 3, self.rng.randint(0, 30))
                self.st.au("TABLE_DML_HISTORY", start_time=start, end_time=start + dt.timedelta(minutes=40),
                           table_id=46407, table_name="TRAINING_FRAMES", schema_id=4313, schema_name="PUBLIC",
                           database_id=436, database_name="ML_SCRATCH_DB", rows_added=int(1024 * 4e6 / 26),
                           rows_removed=0, rows_updated=0)

    # ---- Iceberg and external tables --------------------------------------------------------------------------
    def iceberg_external(self) -> None:
        b = self.b
        # created this morning: SHOW lists it, TABLES does not yet; reads carry its name and id
        self.st.show("iceberg_tables", created_on=b.ts(1, 7), name="ICE_SCORES_V3", database_name="DATA_SCIENCE_PROD_DB",
                     schema_name="MARTS", owner="DATA_SCIENCE_ADMIN", external_volume_name="SNOWFLAKE_MANAGED",
                     catalog_name="SNOWFLAKE", iceberg_table_type="MANAGED", catalog_table_name="ice_scores_v3",
                     catalog_namespace=None, base_location="ice_scores_v3/", can_write_metadata="Y",
                     owner_role_type="ROLE", auto_refresh_status=None)
        self.reads(4, "DATA_SCIENCE_PROD_DB.MARTS.ICE_SCORES_V3", 46408,
                   lambda k, q: k <= 1 and (q.get("warehouse_name") or "").startswith("WH_DATA_SCIENCE"))
        # a vendor's snapshot in an external catalog with auto-refresh off: unchanged for 20 days
        self.table(46409, "PLATFORM_PROD_DB", "RAW", "ICE_VENDOR_SNAPSHOT", "PLATFORM_ADMIN", 120, 80,
                   iceberg="YES", altered=b.ts(20, 9))
        self.st.show("iceberg_tables", created_on=b.ts(120, 9), name="ICE_VENDOR_SNAPSHOT",
                     database_name="PLATFORM_PROD_DB", schema_name="RAW", owner="PLATFORM_ADMIN",
                     external_volume_name="DEMO_EXT_VOL", catalog_name="GLUE_DEMO_INT", iceberg_table_type="UNMANAGED",
                     catalog_table_name="vendor_snapshot", catalog_namespace="analytics",
                     base_location="vendor_snapshot/", can_write_metadata="N", owner_role_type="ROLE",
                     auto_refresh_status=None)
        self.reads(6, "PLATFORM_PROD_DB.RAW.ICE_VENDOR_SNAPSHOT", 46409,
                   lambda k, q: k <= 30 and (q.get("warehouse_name") or "").startswith("WH_PLATFORM"))
        # an auto-refreshed external table whose notifications stopped 12 days ago; still read
        self.table(46410, "MARKETING_PROD_DB", "RAW", "EXT_PARTNER_CONVERSIONS", "MARKETING_WRITE", 200, 0,
                   typ="EXTERNAL TABLE")
        self.st.show("external_tables", created_on=b.ts(200, 9), name="EXT_PARTNER_CONVERSIONS",
                     database_name="MARKETING_PROD_DB", schema_name="RAW", invalid="false", invalid_reason=None,
                     owner="MARKETING_WRITE", stage="S3_AD_PARTNER", location="@S3_AD_PARTNER/conversions/",
                     file_format_name="MARKETING_PROD_DB.RAW.FF_PARQUET_PARTNER", file_format_type="PARQUET",
                     cloud="aws", region="us-east-1",
                     notification_channel="arn:aws:sqs:us-east-1:000000000000:demo-auto-ingest",
                     last_refreshed_on=b.ts(12, 6), table_format=None, owner_role_type="ROLE")
        self.reads(8, "MARKETING_PROD_DB.RAW.EXT_PARTNER_CONVERSIONS", 46410,
                   lambda k, q: k <= 30 and (q.get("warehouse_name") or "").startswith("WH_MARKETING"))

    def search_optimization_dropped(self) -> None:
        """Search optimization billed on a LEGACY_DW_DB lookup table until the database was dropped."""
        b = self.b
        drop = b.ts(demo_storage.DROP_K, 14)
        self.table(46411, "LEGACY_DW_DB", "MARTS", "OLD_LOOKUP", "OPS_ADMIN", 900, 15, retention=14, deleted=drop)
        self.st.au("TABLE_STORAGE_METRICS", id=46411, table_name="OLD_LOOKUP", table_schema_id=4309,
                   table_schema="MARTS", table_catalog_id=434, table_catalog="LEGACY_DW_DB", clone_group_id=46411,
                   is_transient="NO", active_bytes=0, time_travel_bytes=0, failsafe_bytes=int(15 * GB),
                   retained_for_clone_bytes=0, deleted=True, table_created=b.ts(900, 9), table_dropped=drop,
                   table_entered_failsafe=b.ts(demo_storage.FS_K, 14), catalog_dropped=drop, schema_dropped=drop)
        for k in range(demo_storage.DROP_K + 15, demo_storage.DROP_K, -1):
            c = round(3.0 * self.rng.uniform(0.8, 1.2), 4)
            self.st.au("SEARCH_OPTIMIZATION_HISTORY", start_time=b.ts(k, 4), end_time=b.ts(k, 5), credits_used=c,
                       index_id=46411, index_name="SO_OLD_LOOKUP", index_type="SEARCH_OPTIMIZATION",
                       base_table_id=46411, base_table_name="OLD_LOOKUP", schema_id=4309, schema_name="MARTS",
                       database_id=434, database_name="LEGACY_DW_DB")
            self.st.meter("SEARCH_OPTIMIZATION", b.ts(k, 4), c, 46411, "OLD_LOOKUP", "TABLE", "LEGACY_DW_DB", "MARTS")

    # ---- the org: an account opened four days ago -------------------------------------------------------------
    def org_new_account(self) -> None:
        b = self.b
        common = dict(organization_name=data.ORG_NAME, account_name="FAKE_APAC", account_locator="FAKE19",
                      region="AWS_AP_SOUTHEAST_2")
        b.ou("ACCOUNTS", **common, account_url="https://fake_apac.example.com", edition="ENTERPRISE",
             region_group="PUBLIC", is_org_admin=False, is_locked=False, is_managed=False, managed_accounts=0,
             contract_number=4001, created_on=b.ts(4, 9), altered_on=b.ts(4, 9), is_events_account=False,
             comment="APAC reporting, migration started")
        for k in range(4, 0, -1):                        # settling takes three days: one day counts so far
            tb = 0.5 * (1 + 0.1 * (4 - k))
            b.ou("STORAGE_DAILY_HISTORY", **common, service_type="STORAGE", usage_date=b.back(k),
                 average_bytes=tb * TB, credits=None)
            b.ou("USAGE_IN_CURRENCY_DAILY", **common, contract_number=4001, service_level="ENTERPRISE",
                 currency="USD", balance_source="capacity", billing_type="consumption", is_adjustment=False,
                 usage_date=b.back(k), usage_type="storage", usage=tb, usage_in_currency=tb * data.STORAGE_PRICE_TB_DAY,
                 rating_type="storage", service_type="STORAGE")

    def org_hybrid(self) -> None:
        """FAKE_EU also keeps hybrid tables: a second storage service type on the same account and bill."""
        b = self.b
        sdh = self.w.rows.get(("organization_usage", "STORAGE_DAILY_HISTORY"), [])
        cur = self.w.rows.get(("organization_usage", "USAGE_IN_CURRENCY_DAILY"), [])
        tpl = next((r for r in sdh if r["account_locator"] == "FAKE11"), None)
        ctpl = next((r for r in cur if r["account_locator"] == "FAKE11" and r.get("rating_type") == "storage"), None)
        if not tpl or not ctpl:
            return
        days = {r["usage_date"] for r in sdh if r["account_locator"] == "FAKE11"}
        for k in range(365, 0, -1):
            if b.back(k) not in days:
                continue
            tb = 0.3 * (1 + 0.0005 * (365 - k))
            b.ou("STORAGE_DAILY_HISTORY", **dict(tpl, service_type="HYBRID_TABLE_STORAGE", usage_date=b.back(k),
                                                  average_bytes=tb * TB))
            b.ou("USAGE_IN_CURRENCY_DAILY", **dict(ctpl, usage_date=b.back(k), usage=tb,
                                                   usage_in_currency=tb * data.STORAGE_PRICE_TB_DAY,
                                                   service_type="HYBRID_TABLE_STORAGE"))

    # ---- clustering: a big table with no key that dashboards scan, and a key that pays off -----------------------
    def _read(self, c, w, user, start, ms, scanned, total, oid, fqn, qhash, cols) -> None:
        demo_compute._query(self.b, w, user, start, ms, scanned * 16_000_000, "MARTS", None, query_hash=qhash,
                            query_parameterized_hash=qhash, partitions_scanned=scanned, partitions_total=total)
        q = c._rows("QUERY_HISTORY")[-1]
        o = {"objectDomain": "Table", "objectName": fqn, "objectId": oid,
             "columns": [{"columnId": 2100 + i, "columnName": n} for i, n in enumerate(cols)]}
        self.st.au("ACCESS_HISTORY", query_id=q["query_id"], query_start_time=start, user_name=user,
                   direct_objects_accessed=[o], base_objects_accessed=[o], objects_modified=[], policies_referenced=[],
                   root_query_id=q["query_id"])
        hour = start.replace(minute=0, second=0, microsecond=0)
        if not c.billed(w, hour):                        # the warehouse resumed for it
            c.bill(w, hour, min(ms / 3_600_000 + 0.1, 1.0) * data.RATE[q["warehouse_size"]])

    def clustering(self, c) -> None:
        b, rng = self.b, self.rng
        w = c.whs.get("WH_PRODUCT_BI")
        if not w:
            return
        db, sch = "PRODUCT_PROD_DB", "MARTS"
        wide, orders = f"{db}.{sch}.EVENTS_WIDE", f"{db}.{sch}.ORDERS_CLUSTERED"
        self.table(46420, db, sch, "EVENTS_WIDE", "PRODUCT_WRITE", 400, 2048, altered=b.ts(1, 5))
        self.tsm(46420, db, sch, "EVENTS_WIDE", 400, active=2048, tt=60, fs=300)
        self.table(46421, db, sch, "ORDERS_CLUSTERED", "PRODUCT_WRITE", 300, 1024, altered=b.ts(1, 5),
                   clustering_key="LINEAR(ORDER_DATE)")
        self.tsm(46421, db, sch, "ORDERS_CLUSTERED", 300, active=1024, tt=20, fs=150)
        self.st.extend(db, 300, (2048 + 60 + 1024 + 20) * GB)
        self.st.extend(db, 300, 450 * GB, db_col="average_failsafe_bytes", su_col="failsafe_bytes")
        for k in range(95, 0, -1):
            users = demo_compute._users_on(b, w["team"], k) or ["SVC_PRODUCT_REPORTING"]
            if b.back(k).weekday() < 5:                  # weekday dashboards: long scans of nearly every partition
                for i in range(12):
                    total = int(rng.uniform(9000, 11000))
                    self._read(c, w, rng.choice(users), b.ts(k, 10 + i % 6, rng.randint(0, 40)),
                               int(rng.uniform(15, 21) * 60_000), int(total * rng.uniform(0.88, 0.97)), total, 46420,
                               wide, "hcevwide", ("EVENT_TS", "PAGE_ID"))
            for _ in range(16):                          # order lookups by date prune well on the key
                total = int(rng.uniform(4000, 6000))
                self._read(c, w, rng.choice(users), b.ts(k, rng.randint(8, 18), rng.randint(0, 59)),
                           int(rng.uniform(2000, 9000)), int(total * rng.uniform(0.05, 0.15)), total, 46421, orders,
                           "hcorders", ("ORDER_DATE", "CUSTOMER_ID"))
            cr = 0.67 * rng.uniform(0.8, 1.2)            # about 20 credits and 0.6 TB reclustered a month
            start = b.ts(k, 3)
            self.st.au("AUTOMATIC_CLUSTERING_HISTORY", start_time=start, end_time=start + HOUR, credits_used=cr,
                       num_bytes_reclustered=int(20 * GB * cr / 0.67), num_rows_reclustered=int(20 * 4e6 * cr / 0.67),
                       table_id=46421, table_name="ORDERS_CLUSTERED", schema_id=self.w.schema_id[(db, sch)],
                       schema_name=sch, database_id=self.w.dbs[db], database_name=db, version="CLASSIC")
            self.st.meter("AUTO_CLUSTERING", start, cr, 46421, "ORDERS_CLUSTERED", "TABLE", db, sch)

    # ---- backups, a dropped materialized view, Time Travel without a TABLES row ---------------------------------
    def backups(self) -> None:
        rows = self.w.rows.get(("account_usage", "BACKUP_STORAGE_USAGE"), [])
        if not rows:
            return
        for r in rows:
            if r["backup_set_id"] == 9504:               # the deleted set still holds half a terabyte
                r["logical_bytes"] = int(0.5 * TB)
        for i in range(2):                               # a set the role cannot see in BACKUP_SETS
            self.st.au("BACKUP_STORAGE_USAGE", backup_set_id=9505, backup_id=f"9505-{i}", logical_bytes=TB + i * 20 * GB,
                       incremental_bytes_from_previous_backup=i * 20 * GB, decremental_bytes_from_previous_backup=0)

    def mv_dropped(self) -> None:
        """A campaign rollup view refreshed daily until it was dropped eight days ago."""
        b, rng = self.b, self.rng
        db, sch, name = "MARKETING_PROD_DB", "MARTS", "CAMPAIGN_DAILY_MV"
        drop = b.ts(8, 16)
        self.table(46422, db, sch, name, "MARKETING_WRITE", 200, 40, typ="MATERIALIZED VIEW", deleted=drop)
        self.tsm(46422, db, sch, name, 200, fs=40, deleted=True, dropped=drop)
        for k in range(60, 8, -1):
            cr = round(1.2 * rng.uniform(0.7, 1.3), 6)
            start = b.ts(k, 4)
            self.st.au("MATERIALIZED_VIEW_REFRESH_HISTORY", start_time=start, end_time=start + HOUR,
                       credits_used=round(cr, 6), table_id=46422, table_name=name,
                       schema_id=self.w.schema_id[(db, sch)], schema_name=sch, database_id=self.w.dbs[db],
                       database_name=db)
            self.st.meter("MATERIALIZED_VIEW", start, cr, 46422, name, "TABLE", db, sch)

    def orphan_time_travel(self) -> None:
        """A rollup rebuilt daily: twice its size in Time Travel, and TABLES does not list it."""
        self.tsm(46423, "CLICKSTREAM_DB", "CORE", "SESSION_ROLLUP_TMP", 90, active=20, tt=40)
        self.st.extend("CLICKSTREAM_DB", 90, 60 * GB)

    # ---- a table written by MERGEs that read only itself -------------------------------------------------------
    def self_merge(self, c) -> None:
        b, rng = self.b, self.rng
        w = c.whs.get("WH_DATA_SCIENCE_ETL")
        if not w or ("ML_SCRATCH_DB", "PUBLIC") not in self.w.schema_id:
            return
        fqn = "ML_SCRATCH_DB.PUBLIC.TRAINING_FRAMES"
        for k in range(26, 0, -1):
            start = b.ts(k, 3, rng.randint(0, 30))
            ms = int(rng.uniform(15, 25) * 60_000)
            demo_compute._query(b, w, "SVC_DATA_SCIENCE_INGEST", start, ms, int(rng.uniform(2e10, 6e10)), "STAGING",
                                "airflow:dag_training_frames", query_type="MERGE", database_id=436,
                                database_name="ML_SCRATCH_DB", schema_id=4313, schema_name="PUBLIC",
                                query_hash="hcframes", query_parameterized_hash="hcframes",
                                rows_inserted=int(1024 * 4e6 / 26), user_database_id="436", user_schema_id="4313")
            q = c._rows("QUERY_HISTORY")[-1]
            o = {"objectDomain": "Table", "objectName": fqn, "objectId": 46407,
                 "columns": [{"columnId": 2201, "columnName": "FRAME_ID"}]}
            self.st.au("ACCESS_HISTORY", query_id=q["query_id"], query_start_time=start, user_name=q["user_name"],
                       direct_objects_accessed=[o], base_objects_accessed=[o], objects_modified=[o],
                       policies_referenced=[], root_query_id=q["query_id"])
            hour = start.replace(minute=0, second=0, microsecond=0)
            if not c.billed(w, hour):
                c.bill(w, hour, (ms / 3_600_000 + 0.1) * data.RATE[q["warehouse_size"]])

    # ---- a schema of old experiments, mostly unread --------------------------------------------------------------
    def sprawl(self) -> None:
        b = self.b
        db, sch = "FEATURE_STORE_DB", "OLD_EXPERIMENTS"
        self.schema(4314, db, sch, "DATA_SCIENCE_ADMIN", 300)
        for i in range(25):
            tid, name = 46430 + i, f"EXP_{i + 1:02d}_RESULTS"
            gb = 0.0 if i >= 20 else 1.0                 # the last five were created and never filled
            self.table(tid, db, sch, name, "DATA_SCIENCE_WRITE", 300, gb, altered=b.ts(250 - i, 9))
            self.tsm(tid, db, sch, name, 300, active=gb)
            if i < 10:                                   # ten are still read now and then
                self.reads(2, f"{db}.{sch}.{name}", tid,
                           lambda k, q: k <= 80 and (q.get("warehouse_name") or "").startswith("WH_DATA_SCIENCE"))
        self.st.extend(db, 300, 20 * GB)

    # ---- lifecycle policies: runs that stopped, and an attachment that never ran ------------------------------
    def lifecycle(self) -> None:
        b, rng = self.b, self.rng
        pols = self.w.rows.get(("account_usage", "STORAGE_LIFECYCLE_POLICIES"), [])
        refs = [r for r in self.w.rows.get(("account_usage", "POLICY_REFERENCES"), [])
                if r.get("policy_kind") == "STORAGE_LIFECYCLE_POLICY"]
        tpl = next((p for p in pols if p["database"] == "ARCHIVE_DB"), None)
        if not tpl or not refs:
            return
        for pid, name, table, created in ((48404, "SLP_EXPIRE_AP_90D", "AP_AGING_SNAPSHOT", 150),
                                          (48405, "SLP_EXPIRE_EXPORTS_2Y", "EXPORT_202401", 40)):
            self.st.au("STORAGE_LIFECYCLE_POLICIES", **dict(tpl, name=name, id=pid, created_on=b.ts(created, 9),
                                                            last_altered_on=b.ts(created, 9), options=None))
            self.st.au("POLICY_REFERENCES", **dict(refs[0], policy_id=pid, policy_name=name, ref_entity_name=table))
        for k in range(95, 6, -1):                       # expired old rows every night until six days ago
            start = b.ts(k, 0, rng.randint(5, 20))
            end = start + dt.timedelta(minutes=rng.randint(6, 14))
            res = {"EXPIRE": {"start_time": start.isoformat(), "end_time": end.isoformat(), "state": "SUCCEEDED",
                              "error_message_code": None, "error_message": None,
                              "rows_expired": rng.randint(2000, 9000)}}
            self.st.au("STORAGE_LIFECYCLE_POLICY_HISTORY", policy_db="ARCHIVE_DB", policy_schema="LEDGER",
                       policy_name="SLP_EXPIRE_AP_90D", ref_entity_db="ARCHIVE_DB", ref_entity_schema="LEDGER",
                       ref_entity_name="AP_AGING_SNAPSHOT", ref_entity_domain="TABLE", state="SUCCEEDED",
                       start_time=start, end_time=end, execution_result=res, policy_body="<policy body>")
            self.st.meter("STORAGE_LIFECYCLE_POLICY_EXECUTION", b.ts(k, 0), rng.uniform(0.01, 0.03), 48404,
                          "SLP_EXPIRE_AP_90D", "STORAGE_LIFECYCLE_POLICY", "ARCHIVE_DB")

    # ---- stage totals: the account's stage bytes cover every stage the per-stage view lists ---------------------
    def stage_totals(self) -> None:
        rows = self.w.rows
        per_day: dict[str, float] = {}
        for r in rows.get(("account_usage", "STAGE_STORAGE_USAGE_DETAILS"), []):
            k = str(r["usage_date"])[:10]
            per_day[k] = per_day.get(k, 0.0) + (r.get("bytes") or 0)
        if not per_day:
            return
        days = sorted(per_day)
        su = {str(r["usage_date"])[:10]: r for r in rows.get(("account_usage", "STORAGE_USAGE"), [])}
        for h in rows.get(("account_usage", "STAGE_STORAGE_USAGE_HISTORY"), []):
            k = str(h["usage_date"])[:10]
            # days the per-stage view skips or does not reach take the nearest day it has
            near = k if k in per_day else min(days, key=lambda d: abs(dt.date.fromisoformat(d) - dt.date.fromisoformat(k)))
            short = per_day[near] - (h.get("average_stage_bytes") or 0)
            if short > 0:
                h["average_stage_bytes"] = (h.get("average_stage_bytes") or 0) + short
                if k in su:
                    su[k]["stage_bytes"] = (su[k].get("stage_bytes") or 0) + short

    # ---- account parameters the base account leaves out of SHOW PARAMETERS, at Snowflake's defaults ---------------
    def account_parameters(self) -> None:
        have = {r.get("key") for r in self.w.rows.get(("show", "parameters"), [])}
        for key, value, typ in (("LOG_LEVEL", "OFF", "STRING"), ("TRACE_LEVEL", "OFF", "STRING"),
                                ("STATEMENT_QUEUED_TIMEOUT_IN_SECONDS", "0", "NUMBER"),
                                ("EXTERNAL_OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST", "true", "BOOLEAN"),
                                ("OAUTH_ADD_PRIVILEGED_ROLES_TO_BLOCKED_LIST", "true", "BOOLEAN"),
                                ("AUTOCOMMIT", "true", "BOOLEAN"), ("ERROR_ON_NONDETERMINISTIC_MERGE", "true", "BOOLEAN"),
                                ("ERROR_ON_NONDETERMINISTIC_UPDATE", "false", "BOOLEAN"), ("LOCK_TIMEOUT", "43200", "NUMBER"),
                                ("MAX_DATA_EXTENSION_TIME_IN_DAYS", "14", "NUMBER"),
                                ("SUSPEND_TASK_AFTER_NUM_FAILURES", "10", "NUMBER")):
            if key not in have:
                self.st.show("parameters", key=key, value=value, default=value, level="", description="", type=typ)
