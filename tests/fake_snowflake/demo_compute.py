"""Demo compute: warehouse size history, resizes, QAS spend, extra warehouse events, oversized work and budgets.

The Scale step already meters the catalog's warehouses and fills their queries, load, events, SHOW WAREHOUSES and
SHOW RESOURCE MONITORS. This adds what that leaves flat: WAREHOUSE_CONSISTENT size history (some warehouses left
upsized, some sized down, one resized days ago), QUERY_ACCELERATION_HISTORY on the warehouses with QAS (billed in
METERING_HISTORY; demo_billing rolls them up), lifecycle, conversion, cluster and resource-monitor events, a stream of
small queries on the oversized warehouses, one big backfill day, and custom budgets.
"""
from __future__ import annotations

import datetime as dt
import json

from tests.fake_snowflake import demo_wh_fit
from tests.fake_snowflake.data import demo_share

# Size history: (days back the current size began, size before it, who resized it). Current size is the catalog's.
RESIZES = {
    "WH_MARKETING_ADHOC": (40, "Medium", "MARKETING"),      # upsized for a one-off and left there: CRITICAL over 90 days
    "WH_SALES_ETL": (25, "Large", "SALES"),                 # upsized for month end, never sized back
    "WH_RISK_BI": (20, "Medium", "RISK"),                   # a smaller upsize: WARN
    "WH_PLATFORM_DEV": (15, "X-Small", "PLATFORM"),         # small warehouse, small excess: OK
    "WH_PLATFORM_BI": (4, "Medium", "PLATFORM"),            # resized days ago: too new to judge
    "WH_RISK_ETL": (30, "Large", "RISK"),                   # sized down: OK
    "WH_DATA_SCIENCE_ETL": (50, "Medium", "DATA_SCIENCE"),  # sized down, and now it spills
}

# QAS credits per active day: (low, high, last day back it billed; 0 = still on).
QAS = {
    "WH_PRODUCT_BI": (1.0, 2.2, 0),       # a large share of a small warehouse: WARN
    "WH_SALES_ETL": (14.0, 24.0, 0),      # heavy: WARN at 30 days, CRITICAL at 90
    "WH_DATA_SCIENCE_BI": (0.1, 0.4, 20),  # tried and turned off 20 days ago: OK
}

# Small, quick lookups on a big warehouse, per weekday: the oversized pattern.
SMALL_WORK = {"WH_MARKETING_ADHOC": 45, "WH_OPS_BI": 60, "WH_FINANCE_ADHOC": 120, "WH_SALES_ADHOC": 140,
              "WH_PLATFORM_BI": 35}

# A one-off backfill on the biggest warehouse, days back: the account's total spikes to over twice its median.
BACKFILL = ("WH_PLATFORM_ETL", 3, 6, 18)          # warehouse, days back, first hour, hours it ran

DAYS = 95                                 # the 90-day windows plus a margin
LONG_DAYS = 185                           # spend and query volume: a 90-day window and the one before it


def add(b) -> None:
    _qn[0] = 0
    _sess.clear()
    whs = {w["name"]: w for w in b.w.wh if "like" in w}
    _size_history(b, whs)
    _lifecycle_events(b, whs)
    _drop_grants(b, whs)
    _monitor_suspends(b, whs)
    _cluster_events(b)
    _multicluster(b, whs)
    _qas(b, whs)
    _small_work(b, whs)
    _backfill(b, whs)
    _budgets(b)
    _warm_dashboards(b, whs)              # last, so the steps above draw the same random numbers
    # its own random stream: what keeps warehouses awake, short runs, Snowpark-optimized and Gen2 fit, mixed load
    demo_wh_fit.add(b, whs, _query, _ev, _alive, _users_on, GEN2_AT)


def _ev(b, w, ts, name, reason=None, user=None, role=None, size=None, clusters=None, cluster=None, constraint=None,
        state="COMPLETED", wtype=None):
    """One WAREHOUSE_EVENTS_HISTORY row; warehouse-level events have no cluster number, only CONSISTENT has a size."""
    b.au("WAREHOUSE_EVENTS_HISTORY", timestamp=ts, warehouse_id=w["id"], warehouse_name=w["name"],
         cluster_number=cluster, event_name=name, event_reason=reason, event_state=state, user_name=user,
         role_name=role, query_id=None, size=size, cluster_count=clusters, warehouse_type=wtype or w["type"],
         resource_constraint=constraint)


def _alive(b, w, k: int) -> bool:
    c, x = w.get("created_days"), w.get("dropped_days")
    return (c is None or k <= c) and (x is None or k > x)


def _admin(b, team: str) -> str:
    people = [u["name"] for u in b.cat["users"] if u["team"] == team and u["type"] == "PERSON" and not u["disabled"]]
    return people[0] if people else "SYSTEM"


RESIZE_AT = (14, 10)                      # hour and minute of the resize on its day


def _size_at(b, w, ts: dt.datetime) -> str:
    return b.w.size_at(w, ts)


GEN2_AT = 6                               # days back WH_SANDBOX_GEN2 moved from Gen1 to Gen2
SO_TRIAL = ("WH_DATA_SCIENCE_ADHOC", 62, 58)  # converted to Snowpark-optimized and back: days back


def _constraint(b, w, ts: dt.datetime | None = None) -> str | None:
    if w["name"] == "WH_DS_FEATURES" and ts is not None and ts < b.ts(33, 15, 0):
        return "STANDARD_GEN_1"                       # standard until its conversion
    if "GEN2" in w["name"]:
        return "STANDARD_GEN_1" if ts is not None and ts < b.ts(GEN2_AT, 11, 0) else "STANDARD_GEN_2"
    return w.get("constraint") or "STANDARD_GEN_1"


def _so_trial(b, w, ts: dt.datetime) -> bool:
    name, start, end = SO_TRIAL
    return w["name"] == name and b.ts(start, 15, 0) <= ts < b.ts(end, 10, 0)


def _size_history(b, whs) -> None:
    """WAREHOUSE_CONSISTENT every few days (after a resume) with the size it ran at, and the resizes behind it."""
    rng = b.rng
    for name, w in whs.items():
        resize = RESIZES.get(name)
        k = DAYS
        while k >= 1:
            if _alive(b, w, k):
                ts = b.ts(k, rng.randint(6, 9), rng.randint(0, 59))
                trial = _so_trial(b, w, ts)
                con = "MEMORY_16X" if trial else _constraint(b, w, ts)
                _ev(b, w, ts, "WAREHOUSE_CONSISTENT", size=_size_at(b, w, ts), clusters=str(w["min"]), constraint=con,
                    wtype="SNOWPARK-OPTIMIZED" if trial else ("STANDARD" if con.startswith("STANDARD") else None))
            k -= rng.randint(2, 4)
        if resize and _alive(b, w, resize[0]):
            back, _, team = resize
            at = b.ts(back, *RESIZE_AT)
            who = _admin(b, team)
            _ev(b, w, at, "RESIZE_WAREHOUSE", "WAREHOUSE_RESIZE", who, f"{team}_ADMIN", state="STARTED")
            for n in range(1, w["min"] + 1):         # each running cluster is resized too
                _ev(b, w, at, "RESIZE_CLUSTER", "WAREHOUSE_RESIZE", who, f"{team}_ADMIN", cluster=n, state="STARTED")
            _ev(b, w, at + dt.timedelta(minutes=1), "WAREHOUSE_CONSISTENT", size=w["size"], clusters=str(w["min"]),
                constraint=_constraint(b, w, at))


def _lifecycle_events(b, whs) -> None:
    """Create, drop, convert and settings changes, by named people."""
    for name, w in whs.items():
        team = w["team"]
        if w["created_days"] <= DAYS:                  # before the first metered hour and query of that day
            at = b.ts(w["created_days"], 0, 5)
            _ev(b, w, at, "CREATE_WAREHOUSE", None, _admin(b, team), f"{team}_ADMIN")
            _ev(b, w, at + dt.timedelta(seconds=20), "WAREHOUSE_CONSISTENT", size=_size_at(b, w, at),
                clusters=str(w["min"]), constraint=_constraint(b, w, at))
        if w["dropped_days"] is not None:
            _ev(b, w, b.ts(w["dropped_days"], 17, 40), "DROP_WAREHOUSE", None, _admin(b, team), "SYSADMIN")
    if "WH_SANDBOX_GEN2" in whs:                       # created on Gen1, moved to Gen2 a week later
        _convert(b, whs["WH_SANDBOX_GEN2"], b.ts(GEN2_AT, 11, 0), "CONVERT_RESOURCE_CONSTRAINT", "PRODUCT",
                 "STANDARD_GEN_2")
    if "WH_DS_FEATURES" in whs:                        # created standard, converted to Snowpark-optimized
        _convert(b, whs["WH_DS_FEATURES"], b.ts(33, 15, 0), "CONVERT_TO_SNOWPARK_OPTIMIZED", "DATA_SCIENCE",
                 "MEMORY_16X")
    name, start, end = SO_TRIAL
    if name in whs:                                    # tried Snowpark-optimized for a few days, then went back
        w = whs[name]
        _convert(b, w, b.ts(start, 15, 0), "CONVERT_TO_SNOWPARK_OPTIMIZED", w["team"], "MEMORY_16X",
                 "SNOWPARK-OPTIMIZED")
        _convert(b, w, b.ts(end, 10, 0), "CONVERT_TO_STANDARD", w["team"], "STANDARD_GEN_1", "STANDARD")
    for name, back, role in (("WH_PLATFORM_ADHOC", 70, "PLATFORM_ADMIN"), ("WH_PRODUCT_ADHOC", 55, "PRODUCT_ADMIN"),
                             ("WH_MARKETING_BI", 48, "MARKETING_ADMIN")):
        if name in whs:                                # someone raised or turned off auto-suspend
            _ev(b, whs[name], b.ts(back, 16, 30), "ALTER_WAREHOUSE", None, _admin(b, whs[name]["team"]), role)
    for name in ("WH_FINANCE_ADHOC", "WH_SALES_ADHOC", "WH_DATA_SCIENCE_ADHOC"):
        w = whs.get(name)
        if not w:
            continue
        for k in range(3, DAYS, 9):                    # manual resume and suspend from the UI
            if _alive(b, w, k) and b.back(k).weekday() < 5:
                who = _admin(b, w["team"])
                _ev(b, w, b.ts(k, 8, 2), "RESUME_WAREHOUSE", "WAREHOUSE_RESUME", who, f"{w['team']}_WRITE")
                _ev(b, w, b.ts(k, 18, 45), "SUSPEND_WAREHOUSE", "WAREHOUSE_SUSPEND", who, f"{w['team']}_WRITE")


def _convert(b, w, at: dt.datetime, reason: str, team: str, constraint: str, wtype: str | None = None) -> None:
    """The ALTER, the warehouse and cluster conversion events, and the settled state after it."""
    who = _admin(b, team)
    _ev(b, w, at, "ALTER_WAREHOUSE", None, who, f"{team}_ADMIN")
    for state, s in (("STARTED", 0), ("COMPLETED", 40)):
        _ev(b, w, at + dt.timedelta(seconds=s), "CONVERT_WAREHOUSE", reason, who, f"{team}_ADMIN", state=state)
        for n in range(1, w["min"] + 1):
            _ev(b, w, at + dt.timedelta(seconds=s + 2), "CONVERT_CLUSTER", reason, "SYSTEM", cluster=n, state=state)
    _ev(b, w, at + dt.timedelta(minutes=1), "WAREHOUSE_CONSISTENT", size=_size_at(b, w, at), clusters=str(w["min"]),
        constraint=constraint, wtype=wtype)


def _drop_grants(b, whs) -> None:
    """A dropped warehouse's grants go with it, at the DROP."""
    for name, w in whs.items():
        if w["dropped_days"] is None:
            continue
        at = b.ts(w["dropped_days"], 17, 40)
        for r in b.w.rows.get(("account_usage", "GRANTS_TO_ROLES"), []):
            if r["granted_on"] == "WAREHOUSE" and r["name"] == name and r["deleted_on"] is not None:
                r["deleted_on"] = at


def _monitor_suspends(b, whs) -> None:
    """Warehouses under a monitor that hit its quota were suspended by it in the last days of the cycle."""
    full = {r["name"] for r in b.w.rows.get(("show", "resource_monitors"), [])
            if r.get("credit_quota") and r.get("used_credits") is not None
            and r["used_credits"] >= r["credit_quota"] and r.get("suspend_at")}
    for name, w in whs.items():
        if w["monitor"] in full and w["dropped_days"] is None:
            for k in (3, 2, 1):
                _ev(b, w, b.ts(k, 9, 15 + k), "SUSPEND_WAREHOUSE", "RESOURCE_MONITOR_SUSPEND", "SYSTEM", None)


SCALE = {"MULTI_CLUSTER_SCALE_OUT": ("MULTICLUSTER_SPINUP", "RESUME_CLUSTER"),
         "MULTI_CLUSTER_SCALE_IN": ("MULTICLUSTER_SPINDOWN", "SUSPEND_CLUSTER")}
SCALE_FROM = 60                           # days back the Scale step's cluster events reach


def _cluster_events(b) -> None:
    """The Scale step's scale-out rows get the documented reasons, and the RESUME/SUSPEND_CLUSTER row each makes."""
    rows = b.w.rows.get(("account_usage", "WAREHOUSE_EVENTS_HISTORY"), [])
    for r in list(rows):
        if r.get("event_reason") not in SCALE:
            continue
        reason, twin = SCALE[r["event_reason"]]
        r.update(event_reason=reason, size=None, cluster_count=None)
        if r.get("event_state") == "STARTED":          # cluster resume and suspend log only a STARTED row
            rows.append(dict(r, event_name=twin))


def _spin(b, w, start: dt.datetime, end: dt.datetime, n: int) -> None:
    for state, s in (("STARTED", 0), ("COMPLETED", 3)):
        _ev(b, w, start + dt.timedelta(seconds=s), "SPINUP_CLUSTER", "MULTICLUSTER_SPINUP", "SYSTEM", cluster=n,
            state=state)
        _ev(b, w, end + dt.timedelta(seconds=s), "SPINDOWN_CLUSTER", "MULTICLUSTER_SPINDOWN", "SYSTEM", cluster=n,
            state=state)
    _ev(b, w, start, "RESUME_CLUSTER", "MULTICLUSTER_SPINUP", "SYSTEM", cluster=n, state="STARTED")
    _ev(b, w, end, "SUSPEND_CLUSTER", "MULTICLUSTER_SPINDOWN", "SYSTEM", cluster=n, state="STARTED")


def _multicluster(b, whs) -> None:
    """The top cluster spins up on busy weekdays; cluster 2 also before the Scale step's events begin."""
    rng = b.rng
    for name, w in whs.items():
        if w["max"] < 2:
            continue
        for k in range(1, DAYS + 1):
            if not _alive(b, w, k) or b.back(k).weekday() >= 5:
                continue
            if k > SCALE_FROM:
                for _ in range(rng.randint(1, 3)):
                    start = b.ts(k, rng.randint(8, 16), rng.randint(0, 50))
                    _spin(b, w, start, start + dt.timedelta(minutes=rng.randint(10, 50)), 2)
            if w["max"] >= 3 and rng.random() < 0.35:
                start = b.ts(k, rng.randint(9, 15), rng.randint(0, 50))
                _spin(b, w, start, start + dt.timedelta(minutes=rng.randint(10, 70)), w["max"])


def _qas(b, whs) -> None:
    """QUERY_ACCELERATION_HISTORY per hour, its METERING_HISTORY rows, and the accelerated queries."""
    rng = b.rng
    for name, (lo, hi, stop) in QAS.items():
        w = whs.get(name)
        if not w:
            continue
        hours = [9, 11, 14] if w["like"] == "WH_BI" else [1, 3, 5]
        for k in range(LONG_DAYS, stop, -1):
            d = b.back(k)
            if not _alive(b, w, k) or (w["like"] == "WH_BI" and d.weekday() >= 5):
                continue
            total = rng.uniform(lo, hi)
            for h, share in zip(hours, (0.5, 0.3, 0.2)):
                start = b.ts(k, h)
                credits = round(total * share, 6)
                b.au("QUERY_ACCELERATION_HISTORY", start_time=start, end_time=start + dt.timedelta(hours=1),
                     credits_used=credits, warehouse_id=w["id"], warehouse_name=name)
                b.au("METERING_HISTORY", service_type="QUERY_ACCELERATION", start_time=start,
                     end_time=start + dt.timedelta(hours=1), entity_id=w["id"], entity_type="WAREHOUSE", name=name,
                     credits_used_compute=credits, credits_used_cloud_services=0.0, credits_used=credits)
                _accelerated_query(b, w, k, h, rng)


_qn = [0]


def _next_query_id() -> str:
    _qn[0] += 1
    return f"01c-cmp{_qn[0]:07d}"                    # its own prefix, apart from the base and Scale query ids


def _users_on(b, team: str, k: int) -> list[str]:
    return [u["name"] for u in b.cat["users"] if u["team"] == team and u["type"] == "PERSON" and not u["disabled"]
            and u["last_login_days"] is not None and u["last_login_days"] <= k < u["created_days"]]


_sess: dict = {}                          # sessions this module opened: key -> (LOGIN_HISTORY row, SESSIONS row)


def _session(b, user: str, start: dt.datetime, w) -> int:
    """The user's session on the warehouse that day; a new one gets its sign-in and SESSIONS row."""
    key = (user, start.date(), w["name"])
    if key in _sess:
        login, sess = _sess[key]
        if start < sess["created_on"]:                 # opened by the day's first statement
            login["event_timestamp"] = sess["created_on"] = start - dt.timedelta(seconds=2)
        return sess["session_id"]
    if key in b.w.sessions:
        return b.w.sessions[key]                       # opened by the Scale step, which wrote its rows
    b.w._sess_id += 1
    sid = b.w._sess_id
    b.w.sessions[key] = sid
    row = next((r for r in b.w.rows[("account_usage", "USERS")] if r["name"] == user), {})
    first = ("RSA_KEYPAIR" if row.get("has_rsa_public_key")
             else "PASSWORD" if row.get("has_password") else "SAML2_ASSERTION")
    second = "TOTP" if first == "PASSWORD" and row.get("has_mfa") else None   # demo_security sets the enrolled method
    svc, people = b.w.DEMO_CLIENT_MIX[w["like"]]
    mix = svc if user.startswith("SVC_") else people
    ctype, app_id, app = b.w.DEMO_CLIENTS[b.rng.choices(list(mix), weights=list(mix.values()))[0]]
    ip = f"203.0.113.{10 + b.w.users.index(user)}" if user in b.w.users else "203.0.113.200"
    when = start - dt.timedelta(seconds=2)
    login = dict(event_id=sid, event_timestamp=when, event_type="LOGIN", user_name=user, client_ip=ip,
                 reported_client_type=ctype, reported_client_version=app_id.split(" ")[-1],
                 first_authentication_factor=first, second_authentication_factor=second, is_success="YES",
                 connection=None, login_details=json.dumps({"CLIENT_IP": ip}))
    sess = dict(session_id=sid, created_on=when, user_name=user, authentication_method=first, login_event_id=sid,
                client_application_id=app_id, is_open="NO", closed_reason=None,
                client_environment=json.dumps({"APPLICATION": app, "OS": "Linux", "OS_VERSION": "5.15"}))
    b.w.au("LOGIN_HISTORY", login)
    b.w.au("SESSIONS", sess)
    _sess[key] = (login, sess)
    return sid


def _query(b, w, user: str, start: dt.datetime, exec_ms: int, scanned: int, schema: str, tag, **extra) -> None:
    db = f"{w['team']}_PROD_DB"
    comp = int(b.rng.uniform(40, 400))
    qid = _next_query_id()
    qhash = f"hc{w['id'] % 100:02d}{'a' if extra else 's'}"   # one shape per warehouse and kind
    u = next(x for x in b.cat["users"] if x["name"] == user)
    row = dict(
        query_id=qid, query_text="select 1", database_id=b.w.dbs[db], database_name=db,
        schema_id=b.w.schema_id[(db, schema)], schema_name=schema, query_type="SELECT",
        session_id=_session(b, user, start, w), user_name=user, role_name=u["default_role"],
        warehouse_id=w["id"], warehouse_name=w["name"], warehouse_size=_size_at(b, w, start),
        warehouse_type=w["type"], cluster_number=1, query_tag=tag, execution_status="SUCCESS", error_code=None, error_message=None,
        start_time=start, end_time=start + dt.timedelta(milliseconds=comp + exec_ms), total_elapsed_time=comp + exec_ms,
        compilation_time=comp, execution_time=exec_ms, queued_provisioning_time=0, queued_repair_time=0,
        queued_overload_time=0, transaction_blocked_time=0, child_queries_wait_time=0, query_retry_time=0,
        fault_handling_time=0, bytes_scanned=scanned, percentage_scanned_from_cache=round(b.rng.uniform(0, 0.9), 3),
        bytes_written=0, bytes_written_to_result=int(b.rng.uniform(1e3, 1e6)), bytes_read_from_result=0,
        rows_produced=int(b.rng.uniform(1, 5e4)), rows_inserted=0, rows_updated=0, rows_deleted=0, rows_unloaded=0,
        bytes_deleted=0, partitions_scanned=max(1, scanned // 16_000_000), partitions_total=max(10, scanned // 4_000_000),
        bytes_spilled_to_local_storage=0, bytes_spilled_to_remote_storage=0,
        bytes_sent_over_the_network=int(scanned * 0.01), credits_used_cloud_services=b.rng.uniform(0.00002, 0.0004),
        query_load_percent=int(b.rng.uniform(5, 60)), query_acceleration_bytes_scanned=0,
        query_acceleration_partitions_scanned=0, query_hash=qhash, query_hash_version=2,
        query_parameterized_hash=qhash, query_parameterized_hash_version=1, transaction_id=None, role_type="ROLE",
        user_type=u["type"], secondary_role_stats=None, is_client_generated_statement=False,
        user_database_id=str(b.w.dbs[db]), user_schema_id=str(b.w.schema_id[(db, schema)]))
    row.update(extra)
    b.au("QUERY_HISTORY", **row)


def _accelerated_query(b, w, k: int, h: int, rng) -> None:
    """A big scan that QAS took part of, so the spend check can count accelerated statements."""
    users = _users_on(b, w["team"], k) or [f"SVC_{w['team']}_REPORTING"]
    user = rng.choice(users)
    scanned = int(rng.uniform(40e9, 400e9))
    _query(b, w, user, b.ts(k, h, rng.randint(0, 50), rng.randint(0, 59)), int(rng.uniform(60_000, 600_000)), scanned,
           "MARTS" if w["like"] == "WH_BI" else "STAGING", None,
           query_acceleration_bytes_scanned=int(scanned * rng.uniform(0.3, 0.6)),
           query_acceleration_partitions_scanned=int(rng.uniform(200, 4000)),
           query_acceleration_upper_limit_scale_factor=rng.choice([2, 4, 8]))


def _small_work(b, whs) -> None:
    """Many short, small SELECTs on the oversized warehouses: a size or two down would run them as fast."""
    rng = b.rng
    for name, per_day in SMALL_WORK.items():
        w = whs.get(name)
        if not w:
            continue
        t = w["team"].lower()
        tags = [f"bi:tableau:{t}_lookup", None, None] if w["like"] == "WH_BI" else [None]
        for k in range(LONG_DAYS, 0, -1):
            d = b.back(k)
            if not _alive(b, w, k) or d.weekday() >= 5:
                continue
            users = _users_on(b, w["team"], k)
            if not users:
                continue
            for _ in range(int(per_day * rng.uniform(0.7, 1.3) * demo_share(k))):
                start = b.ts(k, rng.randint(8, 17), rng.randint(0, 59), rng.randint(0, 59))
                _query(b, w, rng.choice(users), start, int(rng.uniform(150, 6000)), int(rng.uniform(1e5, 6e8)),
                       "MARTS", rng.choice(tags))


# Dashboards that refresh every few minutes on weekday mornings and read mostly from the warehouse cache:
# the one warehouse whose auto-suspend verdict is "keep warm" (5 min, not 60 s).
WARM_DASHBOARDS = ("WH_MARKETING_BI", 9, 12)     # warehouse, first hour, last hour


def _warm_dashboards(b, whs) -> None:
    name, first, last = WARM_DASHBOARDS
    w = whs.get(name)
    if not w:
        return
    rng = b.rng
    for k in range(DAYS, 0, -1):
        if not _alive(b, w, k) or b.back(k).weekday() >= 5:
            continue
        users = _users_on(b, w["team"], k)
        if not users:
            continue
        t = b.ts(k, first, rng.randint(0, 9))
        end = b.ts(k, last)
        while t < end:
            _query(b, w, rng.choice(users), t, int(rng.uniform(1500, 5000)), int(rng.uniform(2e10, 8e10)), "MARTS",
                   f"bi:tableau:{w['team'].lower()}_dashboard", percentage_scanned_from_cache=round(rng.uniform(0.8, 0.95), 3))
            t += dt.timedelta(seconds=rng.randint(150, 290))


def _backfill(b, whs) -> None:
    """A history backfill ran back to back for most of a day on the biggest warehouse: the account's spike day.

    demo_billing bills the hours these runs take, so metering, attribution and the daily rollups agree."""
    name, k, first, hours = BACKFILL
    w = whs.get(name)
    if not w or not _alive(b, w, k):
        return
    rng = b.rng
    user = f"SVC_{w['team']}_INGEST"
    t = b.ts(k, first)
    end = t + dt.timedelta(hours=hours)
    _ev(b, w, t - dt.timedelta(seconds=30), "RESUME_WAREHOUSE", "WAREHOUSE_AUTORESUME", "SYSTEM", state="STARTED")
    _ev(b, w, t - dt.timedelta(seconds=30), "RESUME_CLUSTER", "WAREHOUSE_AUTORESUME", "SYSTEM", cluster=1,
        state="STARTED")
    while t < end - dt.timedelta(minutes=5):
        ms = min(int(rng.uniform(1.6, 2.4) * 3_600_000), int((end - t).total_seconds() * 1000))
        scanned = int(rng.uniform(2e12, 6e12))
        _query(b, w, user, t, ms, scanned, "STAGING", "dbt:backfill:events_history", query_type="INSERT",
               rows_inserted=int(rng.uniform(2e9, 6e9)), bytes_written=int(scanned * 0.4),
               bytes_written_to_result=0, rows_produced=0, partitions_scanned=int(scanned // 16_000_000),
               partitions_total=int(scanned // 12_000_000), query_load_percent=100)
        t += dt.timedelta(milliseconds=ms + 400)
    for m in range(0, hours * 60, 5):                 # the warehouse ran flat out the whole time
        s = b.ts(k, first) + dt.timedelta(minutes=m)
        b.au("WAREHOUSE_LOAD_HISTORY", start_time=s, end_time=s + dt.timedelta(minutes=5), warehouse_id=w["id"],
             warehouse_name=name, avg_running=1.0, avg_queued_load=0.0, avg_queued_provisioning=0.0, avg_blocked=0.0)
    stop = end + dt.timedelta(seconds=w["suspend"] or 60)
    _ev(b, w, stop, "SUSPEND_WAREHOUSE", "WAREHOUSE_AUTOSUSPEND", "SYSTEM", state="STARTED")
    _ev(b, w, stop, "SUSPEND_CLUSTER", "WAREHOUSE_AUTOSUSPEND", "SYSTEM", cluster=1, state="STARTED")


def _budgets(b) -> None:
    """Custom budgets for a few teams; the rest have none."""
    for name, team, back, comment in (("BUDGET_DATA_SCIENCE", "DATA_SCIENCE", 140, "Serverless and Cortex for DS"),
                                      ("BUDGET_PLATFORM_SERVERLESS", "PLATFORM", 300, "Tasks, pipes and clustering"),
                                      ("BUDGET_MARKETING", "MARKETING", 45, "")):
        b.show("budget_instances", created_on=b.ts(back, 9), name=name, database_name=f"{team}_PROD_DB",
               schema_name="MARTS", current_version="V1", comment=comment, owner=f"{team}_ADMIN",
               owner_role_type="ROLE")
