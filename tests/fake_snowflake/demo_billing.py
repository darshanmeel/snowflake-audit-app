"""Demo billing: the last demo step, so every rollup carries the credits the demo areas added.

Runs after the demo areas. It
- attributes the demo areas' warehouse queries (QUERY_ATTRIBUTION_HISTORY) and keeps each warehouse-hour's
  attributed credits within its metered compute;
- meters every Cortex feature view's credits as AI_SERVICES;
- extends billing history to a year (a lower, slowly growing level before the hourly history starts);
- rebuilds METERING_DAILY_HISTORY from METERING_HISTORY, one row per day and service, with the daily cloud
  services adjustment (free up to 10% of the day's warehouse compute);
- makes this account's ORGANIZATION_USAGE rows copies of its own views: daily metering, warehouse metering,
  storage and data transfer, and USAGE_IN_CURRENCY_DAILY priced from them;
- rebuilds the contract (CONTRACT_ITEMS) and REMAINING_BALANCE_DAILY from what the org was billed;
- rebuilds ANOMALIES_DAILY from the final daily totals.
"""
from __future__ import annotations

import collections
import datetime as dt
import math
import random
import statistics

from tests.fake_snowflake import data, demo_entities

TB = 1024 ** 4
META = {"SHOW", "DESCRIBE", "USE", "SET", "ALTER_SESSION", "BEGIN_TRANSACTION", "COMMIT", "DESCRIBE_QUERY"}
HOUR = dt.timedelta(hours=1)

# service type -> legacy USAGE_TYPE in USAGE_IN_CURRENCY_DAILY
USAGE_TYPE = {
    "WAREHOUSE_METERING": "compute", "AI_SERVICES": "ai services", "AUTO_CLUSTERING": "automatic clustering",
    "MATERIALIZED_VIEW": "materialized views", "SEARCH_OPTIMIZATION": "search optimization",
    "QUERY_ACCELERATION": "query acceleration", "REPLICATION": "replication", "PIPE": "snowpipe",
    "SNOWPIPE_STREAMING": "snowpipe streaming", "SERVERLESS_TASK": "serverless tasks",
    "SERVERLESS_ALERTS": "serverless alerts", "SNOWPARK_CONTAINER_SERVICES": "snowpark container services",
    "HYBRID_TABLE_REQUESTS": "hybrid table requests", "DATA_QUALITY_MONITORING": "data quality monitoring",
    "TELEMETRY_DATA_INGEST": "telemetry data ingest", "CORTEX_CODE_CLI": "cortex code",
    "CORTEX_CODE_SNOWSIGHT": "cortex code",
}


def _hour(t: dt.datetime) -> dt.datetime:
    return t.replace(minute=0, second=0, microsecond=0)


def _org_common() -> dict:
    return dict(organization_name=data.ORG_NAME, account_name=data.ACCOUNT_NAME,
                account_locator=data.ACCOUNT_LOCATOR, region=data.REGION)


# service type -> the feature view that bills it per hour
FEATURE_VIEWS = {
    "SERVERLESS_TASK": "SERVERLESS_TASK_HISTORY", "PIPE": "PIPE_USAGE_HISTORY",
    "QUERY_ACCELERATION": "QUERY_ACCELERATION_HISTORY", "AUTO_CLUSTERING": "AUTOMATIC_CLUSTERING_HISTORY",
    "MATERIALIZED_VIEW": "MATERIALIZED_VIEW_REFRESH_HISTORY", "SEARCH_OPTIMIZATION": "SEARCH_OPTIMIZATION_HISTORY",
    "REPLICATION": "REPLICATION_GROUP_USAGE_HISTORY", "SERVERLESS_ALERTS": "SERVERLESS_ALERT_HISTORY",
    "SNOWPARK_CONTAINER_SERVICES": "SNOWPARK_CONTAINER_SERVICES_HISTORY",
    "DATA_QUALITY_MONITORING": "DATA_QUALITY_MONITORING_USAGE_HISTORY", "HYBRID_TABLE_REQUESTS": "HYBRID_TABLE_USAGE_HISTORY",
    "TELEMETRY_DATA_INGEST": "EVENT_USAGE_HISTORY",
}


YEAR = 365                                           # billing history kept, in days back from the as-of day
LONG = 185                                           # days back the demo areas cover in full
TEMPLATE = (LONG - 28, 28)                           # the earliest four full weeks, replayed further back
LOW = 0.85                                           # the level a year back, vs the template: modest growth
OVERAGE_RATE = 3.9                                   # RATE_SHEET_DAILY 'overage-compute'
CONTRACT = 4001
CAPACITY, FREE_USAGE, ROLLOVER = 250_000.0, 3_500.0, 42_000.0   # USD: the term's capacity, free usage, last term's rollover
MARKETPLACE = 20_000.0                               # the part of capacity set aside for Marketplace purchases
SUPPORT_FEE = 1_500.0                                # USD a month for priority support


def add(w) -> None:
    _base_fill(w)                                    # before attribution, so the replayed hours are covered too
    attribution(w)
    hourly(w)
    history(w)
    daily(w)
    organization(w)
    anomalies(w)


# ---- attribution ------------------------------------------------------------------------------------------------
def _split(start: dt.datetime, end: dt.datetime, credits: float):
    """Credits of one run spread over the clock hours it spans, by time."""
    if end <= start:
        yield _hour(start), credits
        return
    total = (end - start).total_seconds()
    t = start
    while t < end:
        nxt = min(end, _hour(t) + HOUR)
        yield _hour(t), credits * (nxt - t).total_seconds() / total
        t = nxt


def attribution(w) -> None:
    whs = {x["id"]: x for x in w.wh if "like" in x}
    qah = w.rows[("account_usage", "QUERY_ATTRIBUTION_HISTORY")]
    have = {r["query_id"] for r in qah}
    for r in w.rows[("account_usage", "QUERY_HISTORY")]:
        x = whs.get(r.get("warehouse_id"))
        if (x is None or not x["attributed"] or r["query_id"] in have or r["query_type"] in META
                or (r.get("execution_time") or 0) < 100):
            continue                                 # attribution leaves out short queries and idle time
        size = r.get("warehouse_size") or w.size_at(x, r["start_time"])
        credits = r["execution_time"] / 3_600_000 * data.RATE[size] * (1.5 if x["max"] > 1 else 1.0)
        qah.append(dict(query_id=r["query_id"], parent_query_id=None, root_query_id=r["query_id"],
                        warehouse_id=x["id"], warehouse_name=x["name"], query_hash=r.get("query_hash"),
                        query_parameterized_hash=r.get("query_parameterized_hash"), query_tag=r.get("query_tag"),
                        user_name=r["user_name"], start_time=r["start_time"], end_time=r["end_time"],
                        credits_attributed_compute=credits, credits_used_query_acceleration=None))
        have.add(r["query_id"])
    _acceleration(w, whs, qah)

    # the base warehouses' hours are kept within the bill too, including ids outside the catalog
    every = {x["id"]: x for x in w.wh}
    for r in w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]:
        every.setdefault(r["warehouse_id"], dict(id=r["warehouse_id"], name=r["warehouse_name"], attributed=False,
                                                 extra=True))
    for r in qah:
        x = every.setdefault(r["warehouse_id"], dict(id=r["warehouse_id"], name=r["warehouse_name"], extra=True))
        if x.get("extra"):
            x["attributed"] = True                   # it has attributed queries, so attribution is on

    # attributed credits per warehouse-hour, over the hours each query ran
    per_hour: dict = collections.defaultdict(float)
    for r in qah:
        if r["warehouse_id"] in every:
            for h, c in _split(r["start_time"], r["end_time"], r["credits_attributed_compute"] or 0.0):
                per_hour[(r["warehouse_id"], h)] += c
    wmh = {(r["warehouse_id"], r["start_time"]): r for r in w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]
           if r["warehouse_id"] in every}
    mh = {(r["entity_id"], r["start_time"]): r for r in w.rows[("account_usage", "METERING_HISTORY")]
          if r["service_type"] == "WAREHOUSE_METERING" and r.get("entity_id") in every}
    for key in set(per_hour) | set(wmh):
        x = every[key[0]]
        need = per_hour.get(key, 0.0)
        r = wmh.get(key)
        if r is None:                                # a run in an hour nothing billed: bill it, plus a little idle
            compute = need * 1.08
            cs = compute * x.get("cs_share", 0.04)
            w.au("WAREHOUSE_METERING_HISTORY", dict(
                start_time=key[1], end_time=key[1] + HOUR, warehouse_id=x["id"], warehouse_name=x["name"],
                credits_used=compute + cs, credits_used_compute=compute, credits_used_cloud_services=cs,
                credits_attributed_compute_queries=need if x["attributed"] else None))
            w.au("METERING_HISTORY", dict(
                service_type="WAREHOUSE_METERING", start_time=key[1], end_time=key[1] + HOUR, entity_id=x["id"],
                entity_type="WAREHOUSE", name=x["name"], credits_used_compute=compute, credits_used_cloud_services=cs,
                credits_used=compute + cs))
            continue
        if need > r["credits_used_compute"]:         # the queries ran longer than the hour was billed for
            extra = need * 1.05 - r["credits_used_compute"]
            r["credits_used_compute"] += extra
            r["credits_used"] += extra
            m = mh.get(key)
            if m is not None:
                m["credits_used_compute"] += extra
                m["credits_used"] += extra
        if x["attributed"]:
            # a base warehouse keeps its own hour's attribution (a long query sits in its start hour there) and is
            # only raised to the split need, so _idle_shape never trims the hour below what its queries used
            own = r.get("credits_attributed_compute_queries") or 0.0
            r["credits_attributed_compute_queries"] = need if x["id"] in whs or x.get("extra") else max(own, need)
    _idle_shape(w)


# Idle credits as a share of a warehouse's compute. Most warehouses suspend promptly; a few are left running.
IDLE_KEEP = {"WH_ADHOC", "WH_IDLE", "WH_MARKETING_ADHOC", "WH_PLATFORM_ADHOC", "WH_OPS_ADHOC", "WH_RISK_DEV",
             "WH_LEGACY_REPORTS", "WH_PRODUCT_ADHOC",
             "WH_STREAMLIT_APPS"}                             # the bad ones: idle as the Scale step billed it
# WH_DBT_CI: the 60-second minimum of its many short CI runs (demo_wh_fit) is its idle.
IDLE_SHARE = {"WH_SALES_ADHOC": 0.4, "WH_FINANCE_ADHOC": 0.3, "WH_MARKETING_BI": 0.3, "WH_DBT_CI": 0.35,
              "WH_DATA_SCIENCE_ADHOC": 0.25, "WH_ETL": 0.12, "WH_BI": 0.2}
IDLE_BY_LIKE = {"WH_ETL": 0.04, "WH_BI": 0.1, "WH_ADHOC": 0.15, "WH_ML": 0.08, "WH_IDLE": 0.5}


def _idle_shape(w) -> None:
    """Trim each warehouse's idle credits (compute its queries did not use) to its target share of compute."""
    rows = collections.defaultdict(list)
    for r in w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]:
        if r.get("credits_attributed_compute_queries") is not None:
            rows[r["warehouse_id"]].append(r)
    like = {x["id"]: x.get("like") for x in w.wh}
    mh = {(r["entity_id"], r["start_time"]): r for r in w.rows[("account_usage", "METERING_HISTORY")]
          if r["service_type"] == "WAREHOUSE_METERING"}
    for wid, rs in rows.items():
        name = rs[0]["warehouse_name"]
        if name in IDLE_KEEP:
            continue
        share = IDLE_SHARE.get(name, IDLE_BY_LIKE.get(like.get(wid), 0.12))
        used = sum(r["credits_attributed_compute_queries"] for r in rs)
        idle = sum(max(0.0, r["credits_used_compute"] - r["credits_attributed_compute_queries"]) for r in rs)
        want = used * share / (1 - share)
        if idle <= want or idle <= 0:
            continue
        f = want / idle
        for r in rs:
            att = r["credits_attributed_compute_queries"]
            comp = r["credits_used_compute"]
            new = min(comp, att + max(0.0, comp - att) * f)
            k = new / comp if comp else 1.0
            for t in (r, mh.get((wid, r["start_time"]))):
                if t is None:
                    continue
                t["credits_used_compute"] = new
                t["credits_used_cloud_services"] = (t["credits_used_cloud_services"] or 0.0) * k
                t["credits_used"] = new + t["credits_used_cloud_services"]


def _acceleration(w, whs, qah) -> None:
    """Each hour's QAS credits go to the accelerated queries that started in it, by the bytes QAS scanned."""
    scanned = {r["query_id"]: r.get("query_acceleration_bytes_scanned") or 0
               for r in w.rows[("account_usage", "QUERY_HISTORY")] if r.get("warehouse_id") in whs}
    by_hour: dict = collections.defaultdict(list)
    for r in qah:
        if scanned.get(r["query_id"]):
            by_hour[(r["warehouse_id"], _hour(r["start_time"]))].append(r)
    for r in w.rows.get(("account_usage", "QUERY_ACCELERATION_HISTORY"), []):
        rows = by_hour.get((r["warehouse_id"], r["start_time"]))
        if not rows:
            continue
        total = sum(scanned[q["query_id"]] for q in rows)
        for q in rows:
            q["credits_used_query_acceleration"] = (q.get("credits_used_query_acceleration") or 0.0) + (
                float(r["credits_used"]) * scanned[q["query_id"]] / total)


# ---- hourly metering ------------------------------------------------------------------------------------------
def hourly(w) -> None:
    """METERING_HISTORY carries every billed hour: each warehouse hour, and each feature view's credits."""
    mh = w.rows[("account_usage", "METERING_HISTORY")]
    have = {(r["entity_id"], r["start_time"]) for r in mh if r["service_type"] == "WAREHOUSE_METERING"}
    for r in w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")]:
        if (r["warehouse_id"], r["start_time"]) not in have:
            mh.append(dict(service_type="WAREHOUSE_METERING", start_time=r["start_time"], end_time=r["end_time"],
                           entity_id=r["warehouse_id"], entity_type="WAREHOUSE", name=r["warehouse_name"],
                           credits_used_compute=r["credits_used_compute"],
                           credits_used_cloud_services=r["credits_used_cloud_services"], credits_used=r["credits_used"]))
    metered: dict = collections.defaultdict(float)
    for r in mh:
        metered[(r["start_time"].date(), r["service_type"])] += r["credits_used_compute"] or 0.0
    for service, view in FEATURE_VIEWS.items():
        billed: dict = collections.defaultdict(float)
        for r in w.rows.get(("account_usage", view), []):
            billed[r["start_time"].date()] += float(r["credits_used"] or 0)
        for d, c in billed.items():
            gap = c - metered[(d, service)]
            if gap > 1e-6:                           # feature rows the base account never metered
                start = dt.datetime.combine(d, dt.time(13))
                mh.append(dict(service_type=service, start_time=start, end_time=start + HOUR, entity_id=None,
                               entity_type=None, name=service, credits_used_compute=gap,
                               credits_used_cloud_services=0.0, credits_used=gap))
    _cortex(w, mh)


# Cortex views billed as AI_SERVICES: (view, time column, credits column)
AI_VIEWS = [("CORTEX_AI_FUNCTIONS_USAGE_HISTORY", "start_time", "credits"),
            ("CORTEX_ANALYST_USAGE_HISTORY", "start_time", "credits"),
            ("CORTEX_SEARCH_DAILY_USAGE_HISTORY", "usage_date", "credits"),
            ("CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY", "start_time", "credits_used"),
            ("CORTEX_FINE_TUNING_USAGE_HISTORY", "start_time", "token_credits"),
            ("CORTEX_AGENT_USAGE_HISTORY", "start_time", "token_credits"),
            ("CORTEX_PROVISIONED_THROUGHPUT_USAGE_HISTORY", "interval_start_time", "ptu_credits")]


def _day(v) -> dt.date:
    return v.date() if isinstance(v, dt.datetime) else v


def _cortex(w, mh) -> None:
    """AI_SERVICES meters every Cortex view's credits; the base account's untyped Cortex hours get a function row."""
    fns = w.rows.setdefault(("account_usage", "CORTEX_AI_FUNCTIONS_USAGE_HISTORY"), [])
    user = next((u for u in w.rows[("account_usage", "USERS")] if u["name"] == "ANALYST_DAN"), None)
    base = sorted((r for r in mh if r["service_type"] == "AI_SERVICES" and r.get("name") == "CORTEX"),
                  key=lambda r: r["start_time"])
    for i, r in enumerate(base):
        c = r["credits_used_compute"] or 0.0
        fns.append(dict(start_time=r["start_time"], end_time=r["end_time"], function_name="AI_COMPLETE",
                        model_name="mistral-large2", query_id=f"01dbase-{i:07d}", warehouse_id=1002,
                        role_names=["ANALYST_ROLE"], query_tag=None, user_id=str(user["user_id"]) if user else None,
                        metrics=[{"metric": "tokens", "value": int(c * 1.2e6)}], credits=c, is_completed=True))
    used: dict = collections.defaultdict(float)
    for view, when, col in AI_VIEWS:
        for r in w.rows.get(("account_usage", view), []):
            if view == "CORTEX_AI_FUNCTIONS_USAGE_HISTORY" and "PARSE_DOCUMENT" in (r.get("function_name") or "").upper():
                continue                             # billed under document processing, not twice
            used[_day(r[when])] += float(r.get(col) or 0)
    metered: dict = collections.defaultdict(float)
    for r in mh:
        if r["service_type"] == "AI_SERVICES":
            metered[r["start_time"].date()] += r["credits_used_compute"] or 0.0
    for d in sorted(used):
        gap = used[d] - metered[d]
        if gap > 1e-6:                               # view credits nothing metered yet
            start = dt.datetime.combine(d, dt.time(14))
            mh.append(dict(service_type="AI_SERVICES", start_time=start, end_time=start + HOUR, entity_id=None,
                           entity_type=None, name="AI_SERVICES", credits_used_compute=gap,
                           credits_used_cloud_services=0.0, credits_used=gap))


# ---- a year of history -------------------------------------------------------------------------------------------
def _ramp(k: int, start: int, low: float) -> float:
    """1.0 at `start` days back, falling in a line to `low` a year back."""
    return 1.0 - (1.0 - low) * (k - start) / max(1, YEAR - start)


def _shift(r: dict, cols, k_from: int, k_to: int, scale: float, scaled) -> dict:
    """A copy of a row moved from k_from to k_to days back, its amounts scaled."""
    out = dict(r)
    delta = dt.timedelta(days=k_to - k_from)
    for c in cols:
        if out.get(c) is not None:
            out[c] = out[c] - delta
    for c in scaled:
        v = out.get(c)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[c] = int(round(v * scale)) if isinstance(v, int) else v * scale
    return out


BASE_FROM = 60                                       # base warehouses' fixture work reaches this many days back


def _base_fill(w) -> None:
    """The base warehouses' recent four weeks replayed over the older days, so their spend has no steps."""
    base = {x["id"] for x in w.wh if "like" not in x}
    first, cycle = BASE_FROM - 29, 28

    def k_of(t) -> int:
        return (w.as_of - _day(t)).days

    for view, wid in (("WAREHOUSE_METERING_HISTORY", "warehouse_id"), ("METERING_HISTORY", "entity_id")):
        rows = w.rows[("account_usage", view)]

        def mine(r) -> bool:
            return r.get(wid) in base and (view != "METERING_HISTORY" or r["service_type"] == "WAREHOUSE_METERING")

        live = {r[wid] for r in rows if mine(r) and BASE_FROM < k_of(r["start_time"]) <= 130}
        tmpl = collections.defaultdict(list)
        for r in rows:
            if mine(r) and r[wid] in live and first <= k_of(r["start_time"]) < first + cycle:
                tmpl[k_of(r["start_time"])].append(r)
        keep = [r for r in rows if not (mine(r) and r[wid] in live and BASE_FROM < k_of(r["start_time"]) <= LONG)]
        for k in range(BASE_FROM + 1, LONG + 1):
            src = first + (k - first) % cycle
            f = data.demo_share(k) / data.demo_share(src)
            keep.extend(_shift(r, ("start_time", "end_time"), src, k, f, (
                "credits_used_compute", "credits_used_cloud_services", "credits_used",
                "credits_attributed_compute_queries")) for r in tmpl.get(src, []))
        rows[:] = keep


def history(w) -> None:
    """Billing views hold a year: the earliest four weeks of hourly history replayed further back, lower."""
    rng = random.Random(f"{demo_entities.DEMO_SEED}:billing-history")
    first, cycle = TEMPLATE
    au = w.rows
    mh = au[("account_usage", "METERING_HISTORY")]
    have = LONG
    for view, when in (("METERING_HISTORY", "start_time"), ("WAREHOUSE_METERING_HISTORY", "start_time"),
                       ("DATA_TRANSFER_HISTORY", "start_time"), ("METERING_DAILY_HISTORY", "usage_date")):
        rows = au.get(("account_usage", view), [])        # older days held only part of the demo: replayed below
        rows[:] = [r for r in rows if (w.as_of - _day(r[when])).days <= have]
    ks = range(have + 1, YEAR + 1)
    level = {k: _ramp(k, have, LOW) * rng.uniform(0.95, 1.05) for k in ks}
    created = {r["name"]: r.get("created_on") for r in au.get(("show", "warehouses"), [])}

    def back(t) -> int:
        return (w.as_of - _day(t)).days

    def replay(view, scaled, gate=None, when="start_time"):
        rows = au.setdefault(("account_usage", view), [])
        tmpl = collections.defaultdict(list)
        for r in rows:
            if first <= back(r[when]) < first + cycle:
                tmpl[back(r[when])].append(r)
        for k in ks:
            src = first + (k - first) % cycle
            for r in tmpl.get(src, []):
                c = created.get(gate(r)) if gate else None
                if c is not None and c.date() > w.as_of - dt.timedelta(days=k):
                    continue                         # the warehouse did not exist yet
                rows.append(_shift(r, (when, "end_time"), src, k, level[k], scaled))

    credits = ("credits_used_compute", "credits_used_cloud_services", "credits_used",
               "credits_attributed_compute_queries")
    replay("METERING_HISTORY", credits, lambda r: r.get("name") if r["service_type"] == "WAREHOUSE_METERING" else None)
    replay("WAREHOUSE_METERING_HISTORY", credits, lambda r: r["warehouse_name"])
    replay("DATA_TRANSFER_HISTORY", ("bytes_transferred",))
    replay("METERING_DAILY_HISTORY", credits + ("credits_adjustment_cloud_services", "credits_billed"), when="usage_date")
    # storage grows slowly: the first day's bytes, smaller further back
    su = au.get(("account_usage", "STORAGE_USAGE"), [])
    if su:
        r0 = min(su, key=lambda r: r["usage_date"])
        k0 = back(r0["usage_date"])
        for k in range(k0 + 1, YEAR + 1):
            row = dict(r0, usage_date=w.as_of - dt.timedelta(days=k))
            f = _ramp(k, k0, 0.7) * rng.uniform(0.995, 1.005)
            for c, v in r0.items():
                if c.endswith("_bytes") and isinstance(v, (int, float)) and not isinstance(v, bool):
                    row[c] = type(v)(v * f)
            su.append(row)


def _org_history(w) -> None:
    """The other accounts' org billing rows go back a year too, from each account's creation."""
    rng = random.Random(f"{demo_entities.DEMO_SEED}:org-history")
    first, cycle = TEMPLATE
    ou = w.rows
    created = {r["account_locator"]: r.get("created_on") for r in ou.get(("organization_usage", "ACCOUNTS"), [])}
    level: dict = {}
    mdh = ("credits_used_compute", "credits_used_cloud_services", "credits_used", "credits_adjustment_cloud_services",
           "credits_billed")
    views = [("METERING_DAILY_HISTORY", "usage_date", mdh),
             ("USAGE_IN_CURRENCY_DAILY", "usage_date", ("usage", "usage_in_currency")),
             ("STORAGE_DAILY_HISTORY", "usage_date", ("average_bytes",)),
             ("DATA_TRANSFER_HISTORY", "usage_date", ("bytes_transferred",)),
             ("RATE_SHEET_DAILY", "date", ()),
             ("WAREHOUSE_METERING_HISTORY", "start_time", mdh[:3])]
    for view, when, scaled in views:
        rows = ou.get(("organization_usage", view), [])
        tmpl, seen = collections.defaultdict(list), collections.defaultdict(set)
        for r in rows:
            if r.get("account_locator") == data.ACCOUNT_LOCATOR:
                continue                             # this account's rows are copies of its own views
            k = (w.as_of - _day(r[when])).days
            seen[r["account_locator"]].add(k)
            if (first <= k < first + cycle and not r.get("is_adjustment")
                    and r.get("balance_source") in (None, "capacity")):
                tmpl[(r["account_locator"], k)].append(r)
        moved = (when, "end_time") if when == "start_time" else (when,)
        for loc in sorted(seen):
            c = created.get(loc)
            for k in range(first + cycle, YEAR + 1):
                if k in seen[loc] or (c is not None and c.date() > w.as_of - dt.timedelta(days=k)):
                    continue
                src = first + (k - first) % cycle
                if (loc, k) not in level:
                    level[(loc, k)] = _ramp(k, first + cycle, LOW) * rng.uniform(0.95, 1.05)
                f = _ramp(k, first + cycle, 0.75) if view == "STORAGE_DAILY_HISTORY" else level[(loc, k)]
                for r in tmpl.get((loc, src), []):
                    rows.append(_shift(r, moved, src, k, f, scaled))


# ---- daily metering ----------------------------------------------------------------------------------------------
def daily(w) -> None:
    au = w.rows[("account_usage", "METERING_HISTORY")]
    hourly: dict = collections.defaultdict(lambda: [0.0, 0.0])
    for r in au:
        a = hourly[(r["start_time"].date(), r["service_type"])]
        a[0] += r["credits_used_compute"] or 0.0
        a[1] += r["credits_used_cloud_services"] or 0.0
    old: dict = collections.defaultdict(lambda: [0.0, 0.0])
    for r in w.rows[("account_usage", "METERING_DAILY_HISTORY")]:
        a = old[(r["usage_date"], r["service_type"])]
        a[0] += r["credits_used_compute"] or 0.0
        a[1] += r["credits_used_cloud_services"] or 0.0
    # Credits the base account bills only by day get their hour too, so the two views agree.
    for key, (comp, cs) in old.items():
        if key[1] == "WAREHOUSE_METERING":
            continue                                 # warehouse hours are all in METERING_HISTORY already
        h = hourly[key]
        dc, dcs = max(0.0, comp - h[0]), max(0.0, cs - h[1])
        if dc > 1e-6 or dcs > 1e-6:
            start = dt.datetime.combine(key[0], dt.time(12))
            w.au("METERING_HISTORY", dict(
                service_type=key[1], start_time=start, end_time=start + HOUR, entity_id=None, entity_type=None,
                name=key[1], credits_used_compute=dc, credits_used_cloud_services=dcs, credits_used=dc + dcs))
            h[0] += dc
            h[1] += dcs
    by_day: dict = collections.defaultdict(dict)
    for (d, service), v in hourly.items():
        by_day[d][service] = v
    rows = []
    for d in sorted(by_day):
        services = by_day[d]
        # cloud services are free up to 10% of the day's warehouse compute; the rest is billed
        room = 0.1 * services.get("WAREHOUSE_METERING", [0.0, 0.0])[0]
        for service in sorted(services, key=lambda s: (s != "WAREHOUSE_METERING", s)):
            comp, cs = services[service]
            adj = -min(cs, room)
            room += adj
            rows.append(dict(service_type=service, usage_date=d, credits_used_compute=comp,
                             credits_used_cloud_services=cs, credits_used=comp + cs,
                             credits_adjustment_cloud_services=adj, credits_billed=comp + cs + adj))
    w.rows[("account_usage", "METERING_DAILY_HISTORY")] = rows


# ---- organization ----------------------------------------------------------------------------------------------
def organization(w) -> None:
    loc = data.ACCOUNT_LOCATOR
    common = _org_common()
    ou = w.rows

    def mine(r):
        return r.get("account_locator") == loc

    # daily metering and warehouse metering: copies of the account's own
    ou[("organization_usage", "METERING_DAILY_HISTORY")] = (
        [r for r in ou[("organization_usage", "METERING_DAILY_HISTORY")] if not mine(r)]
        + [dict(common, **r) for r in ou[("account_usage", "METERING_DAILY_HISTORY")]])
    ou[("organization_usage", "WAREHOUSE_METERING_HISTORY")] = (
        [r for r in ou[("organization_usage", "WAREHOUSE_METERING_HISTORY")] if not mine(r)]
        + [dict(common, service_type="WAREHOUSE_METERING", start_time=r["start_time"], end_time=r["end_time"],
                warehouse_id=r["warehouse_id"], warehouse_name=r["warehouse_name"],
                credits_used_compute=r["credits_used_compute"],
                credits_used_cloud_services=r["credits_used_cloud_services"], credits_used=r["credits_used"])
           for r in ou[("account_usage", "WAREHOUSE_METERING_HISTORY")]])

    # storage: the account's own daily bytes
    storage = {}
    for r in ou[("account_usage", "STORAGE_USAGE")]:
        storage[r["usage_date"]] = sum(r.get(c) or 0 for c in (
            "storage_bytes", "stage_bytes", "failsafe_bytes", "hybrid_table_storage_bytes",
            "archive_storage_cool_bytes", "archive_storage_cold_bytes", "archive_storage_retrieval_temp_bytes"))
    ou[("organization_usage", "STORAGE_DAILY_HISTORY")] = (
        [r for r in ou[("organization_usage", "STORAGE_DAILY_HISTORY")] if not mine(r)]
        + [dict(common, service_type="STORAGE", usage_date=d, average_bytes=b, credits=None)
           for d, b in sorted(storage.items())])

    # data transfer: the account's own, by day and route
    routes: dict = collections.defaultdict(int)
    for r in ou[("account_usage", "DATA_TRANSFER_HISTORY")]:
        routes[(r["start_time"].date(), r["source_cloud"], r["source_region"], r["target_cloud"], r["target_region"],
                r["transfer_type"])] += r["bytes_transferred"] or 0
    ou[("organization_usage", "DATA_TRANSFER_HISTORY")] = (
        [r for r in ou[("organization_usage", "DATA_TRANSFER_HISTORY")] if not mine(r)]
        + [dict(common, usage_date=d, source_cloud=sc, source_region=sr, target_cloud=tc, target_region=tr,
                bytes_transferred=b, transfer_type=tt) for (d, sc, sr, tc, tr, tt), b in sorted(
                    routes.items(), key=lambda kv: (kv[0][0], str(kv[0][1:])))])

    _org_history(w)

    # currency: rebuilt from the rows above. Overage, rebates and adjustments stay; overage replaces capacity,
    # at most the day's metered credits, at the overage rate.
    metered: dict = {}
    for r in ou[("account_usage", "METERING_DAILY_HISTORY")]:
        metered[(r["usage_date"], r["service_type"])] = (
            r["credits_used_compute"] if r["service_type"] == "WAREHOUSE_METERING" else r["credits_billed"])
    keep, overage = [], collections.defaultdict(float)
    for r in ou[("organization_usage", "USAGE_IN_CURRENCY_DAILY")]:
        if not mine(r):
            keep.append(r)
        elif r.get("balance_source") == "overage" and not r.get("is_adjustment"):
            key = (r["usage_date"], r["service_type"])
            usage = min(r["usage"] or 0.0, max(0.0, metered.get(key, 0.0) - overage[key]))
            if usage > 0.0005:
                keep.append(dict(r, usage=usage, usage_in_currency=usage * OVERAGE_RATE))
                overage[key] += usage
        elif r.get("balance_source") == "rebate":
            keep.append(dict(r, billing_type="rebate"))
        elif r.get("is_adjustment") or r.get("balance_source") not in (None, "capacity"):
            keep.append(r)
    bill = dict(common, contract_number=4001, service_level="ENTERPRISE", currency="USD", balance_source="capacity",
                billing_type="consumption", is_adjustment=False)
    out = []

    def row(d, service, usage_type, rating, usage, amount):
        if usage > 0.0005:
            out.append(dict(bill, usage_date=d, usage_type=usage_type, usage=usage, usage_in_currency=amount,
                            rating_type=rating, service_type=service))

    for r in ou[("account_usage", "METERING_DAILY_HISTORY")]:
        d, service = r["usage_date"], r["service_type"]
        over = overage.get((d, service), 0.0)
        if service == "WAREHOUSE_METERING":
            comp = max(0.0, r["credits_used_compute"] - over)
            row(d, service, "compute", "compute", comp, comp * data.CREDIT_PRICE)
            cs = r["credits_used_cloud_services"] + r["credits_adjustment_cloud_services"]
            row(d, "CLOUD_SERVICES", "cloud services", "compute", cs, cs * data.CREDIT_PRICE)
        else:
            billed = max(0.0, r["credits_billed"] - over)
            row(d, service, USAGE_TYPE.get(service, service.lower().replace("_", " ")), "compute", billed,
                billed * data.CREDIT_PRICE)
    for d, b in sorted(storage.items()):
        row(d, "STORAGE", "storage", "storage", b / TB, b / TB * data.STORAGE_PRICE_TB_DAY)
    per_day: dict = collections.defaultdict(lambda: [0.0, 0.0])
    for (d, sc, _sr, tc, _tr, _tt), b in routes.items():
        per_day[d][0] += b / TB
        per_day[d][1] += b / TB * (20.0 if tc == sc else 90.0)  # same cloud is cheaper than leaving it
    for d, (tb, usd) in sorted(per_day.items()):
        row(d, "DATA_TRANSFER", "data transfer", "data_transfer", tb, usd)
    # priority support: a flat monthly fee, not a credit service
    for d in sorted({r["usage_date"] for r in out if r["usage_date"].day == 1}):
        out.append(dict(bill, usage_date=d, usage_type="priority support", usage=SUPPORT_FEE,
                        usage_in_currency=SUPPORT_FEE, billing_type="priority support", rating_type="other",
                        service_type=None))
    uic = keep + out
    ou[("organization_usage", "USAGE_IN_CURRENCY_DAILY")] = uic
    _contract(w, uic)


def _contract(w, uic) -> None:
    """The contract and its daily balance, drawn down by what the org was billed.

    Free usage drains first, then last term's rollover, then capacity; overage builds the on-demand balance
    until the month closes. An 'Additional capacity' amendment tops capacity up before it runs out."""
    ou = w.rows
    items = ou.get(("organization_usage", "CONTRACT_ITEMS"), [])
    base = next((r for r in items if r["contract_number"] == CONTRACT), None)
    if base is None:
        return
    start, end = base["start_date"], base["end_date"]
    last = w.as_of - dt.timedelta(days=1)         # the balance lags a day behind usage

    # label the rows that free usage and rollover paid for, oldest first; a row that crosses a pool is split
    pools = [["free usage", FREE_USAGE], ["rollover", ROLLOVER]]
    draw = sorted((r for r in uic if r.get("contract_number") == CONTRACT and r.get("balance_source") == "capacity"
                   and start <= r["usage_date"] <= last and (r["usage_in_currency"] or 0) > 0),
                  key=lambda r: (r["usage_date"], r["account_locator"], r.get("service_type") or "", r["usage_type"]))
    for r in draw:
        pool = next((p for p in pools if p[1] > 1e-9), None)
        if pool is None:
            break
        amt = r["usage_in_currency"]
        if amt <= pool[1]:
            r["balance_source"] = pool[0]
            pool[1] -= amt
            continue
        part = pool[1] / amt
        uic.append(dict(r, balance_source=pool[0], usage=r["usage"] * part, usage_in_currency=pool[1]))
        r["usage"] *= 1 - part
        r["usage_in_currency"] = amt - pool[1]
        pool[1] = 0.0

    spent = collections.defaultdict(lambda: collections.defaultdict(float))
    for r in uic:
        if r.get("contract_number") == CONTRACT and start <= r["usage_date"] <= last:
            spent[r["usage_date"]][r.get("balance_source")] += r["usage_in_currency"] or 0.0
    days = [start + dt.timedelta(days=i) for i in range((last - start).days + 1)]

    # the amendment: capacity is topped up the day after less than a week of it is left
    used = sum(spent[d]["capacity"] for d in days)
    recent = sum(sum(v for k, v in spent[d].items() if k != "overage") for d in days[-30:]) / 30
    cap, topup_day = CAPACITY, None
    for i, d in enumerate(days):
        cap -= spent[d]["capacity"]
        week = sum(spent[x]["capacity"] for x in days[max(0, i - 6):i + 1])
        if cap < week:
            topup_day = d + dt.timedelta(days=1)
            break
    # sized to leave about six weeks of the current spend, so it runs short before the term ends
    topup = math.ceil((used - CAPACITY + 45 * recent) / 50_000) * 50_000 if topup_day else 0.0

    org = dict(organization_name=data.ORG_NAME, contract_number=CONTRACT, currency="USD")
    ou[("organization_usage", "CONTRACT_ITEMS")] = [r for r in items if r["contract_number"] != CONTRACT] + [
        dict(org, start_date=start, end_date=end, expiration_date=end, contract_item="Capacity", amount=CAPACITY,
             contract_modified_date=start),
        dict(org, start_date=start, end_date=end, expiration_date=end, contract_item="Free usage",
             amount=FREE_USAGE, contract_modified_date=start)] + ([
        dict(org, start_date=topup_day, end_date=end, expiration_date=end, contract_item="Additional capacity",
             amount=float(topup), contract_modified_date=topup_day)] if topup_day else [])

    free, roll, cap, on_demand, rows = FREE_USAGE, ROLLOVER, CAPACITY, 0.0, []
    for d in days:
        if d == topup_day:
            cap += topup
        if d.day == 1:
            on_demand = 0.0                          # last month's on-demand usage was invoiced and paid
        s = spent[d]
        free -= s["free usage"]
        roll -= s["rollover"]
        cap -= s["capacity"]
        on_demand -= s["overage"]
        rows.append(dict(org, date=d, free_usage_balance=round(free, 2) + 0.0, capacity_balance=round(cap, 2),
                         on_demand_consumption_balance=round(on_demand, 2) + 0.0, rollover_balance=round(roll, 2) + 0.0,
                         marketplace_capacity_drawdown_balance=round(min(max(cap, 0.0), MARKETPLACE), 2)))
    ou[("organization_usage", "REMAINING_BALANCE_DAILY")] = rows


# ---- anomalies ---------------------------------------------------------------------------------------------------
def anomalies(w) -> None:
    """Snowflake's daily cost anomalies: a forecast from the same weekday of the four weeks before, and a band."""
    tot: dict = collections.defaultdict(float)
    for r in w.rows[("account_usage", "METERING_DAILY_HISTORY")]:
        tot[r["usage_date"]] += r["credits_billed"] or 0.0
    rows = []
    for k in range(1, 171):                          # it needs 30 days of history before it forecasts
        d = w.as_of - dt.timedelta(days=k)
        prev = [tot.get(d - dt.timedelta(days=7 * i), 0.0) for i in range(1, 5)]
        if d - dt.timedelta(days=28) < min(tot, default=d):
            continue
        fc = statistics.median(prev)
        spread = max(fc * 0.3, 15.0)
        actual = tot.get(d, 0.0)
        hi, lo = fc + 1.5 * spread, max(0.0, fc - 1.5 * spread)
        rows.append(dict(date=d, anomaly_id=f"an-{d.isoformat()}", is_anomaly=actual > hi or actual < lo,
                         actual_value=actual, upper_bound=hi, lower_bound=lo, forecasted_value=fc))
    w.rows[("account_usage", "ANOMALIES_DAILY")] = rows
