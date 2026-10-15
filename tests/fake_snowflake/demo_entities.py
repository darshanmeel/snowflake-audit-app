"""The demo account's extra entities: teams, warehouses, users, roles, databases, tables, tasks and pipes.

Pure data from its own seeded generator, so the base fake account (and the test DB) never changes.
Every demo_*.py module reads its names and ids from here, so the views agree with each other.
Ids sit in ranges the base account never uses. Nothing here is a real name.
"""
from __future__ import annotations

import random
from functools import lru_cache

DEMO_SEED = 20261005

TEAMS = ["FINANCE", "MARKETING", "SALES", "PLATFORM", "DATA_SCIENCE", "PRODUCT", "RISK", "OPS"]
COST_CENTERS = {"FINANCE": "CC-1100", "MARKETING": "CC-1200", "SALES": "CC-1300", "PLATFORM": "CC-1400",
                "DATA_SCIENCE": "CC-1500", "PRODUCT": "CC-1600", "RISK": "CC-1700", "OPS": "CC-1800"}
ENVS = ["prod", "dev", "test"]

# Archetypes match the base warehouses' query and metering profiles in data.py.
ARCHETYPES = ["WH_ETL", "WH_BI", "WH_ADHOC", "WH_IDLE", "WH_ADAPTIVE", "WH_ML"]

FIRST = ["AMIR", "BEA", "CHEN", "DIEGO", "ELIF", "FARAH", "GUS", "HANA", "IKE", "JUNO", "KAI", "LENA", "MILO",
         "NIA", "OMAR", "PIA", "QUINN", "RIO", "SANA", "TEO", "UMA", "VIK", "WREN", "XAN", "YARA", "ZED"]
LAST = ["ABEL", "BRANDT", "CRUZ", "DORN", "EKER", "FALK", "GRAY", "HOLM", "IVES", "JOST", "KERR", "LUND", "MORA",
        "NOOR", "OSTA", "PRYS", "QUILL", "ROOS", "STEN", "TAMM", "ULLA", "VOSS", "WEIR", "YOST", "ZANE"]

TABLE_STEMS = ["ORDERS", "CUSTOMERS", "INVOICES", "PAYMENTS", "EVENTS", "SESSIONS", "CAMPAIGNS", "LEADS",
               "ACCOUNTS", "LEDGER", "FORECAST", "INVENTORY", "SHIPMENTS", "TICKETS", "FEATURES", "SCORES",
               "CLAIMS", "POLICIES", "PRICES", "RETURNS", "CLICKS", "PAGEVIEWS", "SUBSCRIPTIONS", "CHURN"]


@lru_cache(maxsize=1)
def catalog() -> dict:
    """{teams, warehouses, roles, users, databases, schemas, tables, tasks, pipes}: lists of dicts."""
    rng = random.Random(DEMO_SEED)
    out: dict = {"teams": TEAMS, "cost_centers": COST_CENTERS}

    # Warehouses: three per team, plus a few shared ones. Sizes, types and settings vary.
    sizes = ["X-Small", "Small", "Medium", "Large", "X-Large", "2X-Large"]
    whs = []
    wid = 3000
    purposes = [("ETL", "WH_ETL"), ("BI", "WH_BI"), ("ADHOC", "WH_ADHOC")]
    for team in TEAMS:
        for purpose, like in purposes:
            wid += 1
            env = "prod" if purpose != "ADHOC" else rng.choice(["dev", "prod"])
            size = rng.choice(sizes[:4] if purpose == "ADHOC" else sizes[1:])
            whs.append(dict(
                id=wid, name=f"WH_{team}_{purpose}", like=like, team=team, env=env, size=size,
                type="STANDARD", min=1, max=rng.choice([1, 1, 2, 3, 4]) if purpose == "BI" else 1,
                suspend=rng.choice([60, 60, 120, 300, 600, 1800, 3600]) if rng.random() > 0.08 else 0,
                monitor=f"RM_{team}" if rng.random() < 0.6 else None, owner=f"{team}_ADMIN",
                attributed=True, tagged=rng.random() < 0.7))
    for name, like, size, typ, team in [("WH_DS_TRAIN", "WH_ML", "Large", "SNOWPARK-OPTIMIZED", "DATA_SCIENCE"),
                                        ("WH_DS_FEATURES", "WH_ML", "Medium", "SNOWPARK-OPTIMIZED", "DATA_SCIENCE"),
                                        ("WH_SHARED_ADAPTIVE", "WH_ADAPTIVE", "Medium", "ADAPTIVE", "PLATFORM"),
                                        ("WH_LEGACY_REPORTS", "WH_IDLE", "Small", "STANDARD", "OPS"),
                                        ("WH_TEMP_MIGRATION", "WH_IDLE", "X-Large", "STANDARD", "PLATFORM"),
                                        ("WH_SANDBOX_GEN2", "WH_ADHOC", "Small", "STANDARD", "PRODUCT")]:
        wid += 1
        whs.append(dict(id=wid, name=name, like=like, team=team, env="prod" if "LEGACY" not in name else "dev",
                        size=size, type=typ, min=1, max=1, suspend=rng.choice([60, 300, 3600]),
                        monitor=None, owner=f"{team}_ADMIN", attributed=typ != "ADAPTIVE",
                        tagged=rng.random() < 0.5))
    xr = random.Random(f"{DEMO_SEED}:wh-extra")       # its own stream, so the rest of the catalog stays put
    for name, like, size, team, env in [("WH_FINANCE_DEV", "WH_ADHOC", "X-Small", "FINANCE", "dev"),
                                        ("WH_SALES_DEV", "WH_ADHOC", "X-Small", "SALES", "dev"),
                                        ("WH_PLATFORM_DEV", "WH_ADHOC", "Small", "PLATFORM", "dev"),
                                        ("WH_RISK_DEV", "WH_ADHOC", "X-Small", "RISK", "dev"),
                                        ("WH_DBT_CI", "WH_ETL", "Small", "PLATFORM", "test"),
                                        ("WH_STREAMLIT_APPS", "WH_BI", "X-Small", "PRODUCT", "prod"),
                                        ("WH_REVERSE_ETL", "WH_ETL", "Medium", "MARKETING", "prod"),
                                        ("WH_RISK_MODELS", "WH_ML", "Medium", "RISK", "prod")]:
        wid += 1
        whs.append(dict(id=wid, name=name, like=like, team=team, env=env, size=size, type="STANDARD", min=1,
                        max=1, suspend=xr.choice([60, 60, 120, 300]), monitor=f"RM_{team}" if xr.random() < 0.5 else None,
                        owner=f"{team}_ADMIN", attributed=True, tagged=xr.random() < 0.6))
    _warehouse_traits(whs)
    out["warehouses"] = whs

    # Roles: read, write and admin per team, plus service roles.
    roles = []
    rid = 60000
    for team in TEAMS:
        for kind in ("READ", "WRITE", "ADMIN"):
            rid += 1
            roles.append(dict(id=rid, name=f"{team}_{kind}", team=team, kind=kind))
    for name in ("SVC_INGEST_ROLE", "SVC_REPORTING_ROLE", "SVC_ML_ROLE", "AUDITOR_ROLE", "TEMP_CONTRACTOR_ROLE"):
        rid += 1
        roles.append(dict(id=rid, name=name, team="PLATFORM", kind="SERVICE" if name.startswith("SVC") else "OTHER"))
    out["roles"] = roles

    # Users: people per team, service users, a few stale, locked or without MFA.
    users = []
    uid = 50000
    seen = set()
    for team in TEAMS:
        for _ in range(rng.randint(7, 12)):
            while True:
                name = f"{rng.choice(FIRST)}_{rng.choice(LAST)}"
                if name not in seen:
                    seen.add(name)
                    break
            uid += 1
            last = rng.choice([0, 1, 1, 2, 3, 5, 8, 14, 30, 45, 95, 200, None])
            users.append(dict(
                id=uid, name=name, type="PERSON", team=team, default_role=f"{team}_{rng.choice(['READ', 'READ', 'WRITE'])}",
                has_password=rng.random() < 0.85, has_mfa=rng.random() < 0.6, has_rsa=False,
                last_login_days=last, pw_age_days=rng.randint(5, 800), disabled=rng.random() < 0.05,
                created_days=rng.randint(40, 1200), env=None))
    for team in TEAMS:
        for purpose in ("INGEST", "REPORTING"):
            uid += 1
            users.append(dict(
                id=uid, name=f"SVC_{team}_{purpose}", type="SERVICE" if rng.random() < 0.8 else "LEGACY_SERVICE",
                team=team, default_role=f"{team}_WRITE" if purpose == "INGEST" else f"{team}_READ",
                has_password=rng.random() < 0.2, has_mfa=None, has_rsa=rng.random() < 0.8, last_login_days=0,
                pw_age_days=rng.randint(100, 1500), disabled=False, created_days=rng.randint(300, 1500), env="prod"))
    for u in users:                                   # nobody signs in or sets a password before they exist
        if u["last_login_days"] is not None:
            u["last_login_days"] = min(u["last_login_days"], u["created_days"])
        u["pw_age_days"] = min(u["pw_age_days"], u["created_days"])
    out["users"] = users

    # Databases, schemas and tables: a prod and a dev database per team, sizes on a long tail.
    dbs, schemas, tables = [], [], []
    dbid, sid, tid = 400, 4000, 40000
    for team in TEAMS:
        for env in ("PROD", "DEV"):
            dbid += 1
            dname = f"{team}_{env}_DB"
            dbs.append(dict(id=dbid, name=dname, team=team, env=env.lower(), owner=f"{team}_ADMIN",
                            transient=env == "DEV", retention=rng.choice([1, 1, 7, 14, 30, 90]) if env == "PROD" else 0,
                            tagged=rng.random() < 0.65))
            for sname in ("RAW", "STAGING", "MARTS") if env == "PROD" else ("SCRATCH",):
                sid += 1
                schemas.append(dict(id=sid, name=sname, db=dname, db_id=dbid, team=team,
                                    managed=sname == "MARTS" and rng.random() < 0.5))
                for _ in range(rng.randint(3, 8) if env == "PROD" else rng.randint(1, 3)):
                    tid += 1
                    stem = rng.choice(TABLE_STEMS)
                    gb = round(rng.paretovariate(1.1) * rng.choice([0.05, 0.5, 2, 10]), 3)
                    tables.append(dict(
                        id=tid, name=f"{stem}_{tid % 1000:03d}", db=dname, db_id=dbid, schema=sname, schema_id=sid,
                        team=team, type=rng.choice(["BASE TABLE"] * 8 + ["VIEW", "MATERIALIZED VIEW"]),
                        transient=env == "DEV", gb=gb, rows=int(gb * rng.uniform(2e6, 2e7)),
                        clustered=gb > 50 and rng.random() < 0.5, last_read_days=rng.choice([0, 1, 2, 7, 30, 90, 200, None]),
                        last_altered_days=rng.choice([0, 1, 3, 10, 60, 300]), created_days=rng.randint(30, 900),
                        pii=stem in ("CUSTOMERS", "ACCOUNTS", "PAYMENTS", "CLAIMS", "LEADS") and rng.random() < 0.8,
                        tagged=rng.random() < 0.55))
    out["databases"], out["schemas"], out["tables"] = dbs, schemas, tables

    # Tasks: some on warehouses, some serverless, a few root tasks with children, varied health.
    tasks = []
    tkid = 70000
    for team in TEAMS:
        prod_db = f"{team}_PROD_DB"
        for k in range(rng.randint(3, 7)):
            tkid += 1
            serverless = rng.random() < 0.35
            tasks.append(dict(
                id=tkid, name=f"{team}_LOAD_{k + 1:02d}", db=prod_db, schema="STAGING", team=team,
                warehouse=None if serverless else f"WH_{team}_ETL", schedule=rng.choice(
                    ["USING CRON 0 * * * * UTC", "USING CRON 0 2 * * * UTC", "5 MINUTE", "15 MINUTE", "60 MINUTE"]),
                root=None if k < 2 else f"{prod_db}.STAGING.{team}_LOAD_01",
                fail_rate=rng.choice([0.0, 0.0, 0.01, 0.05, 0.2, 0.6]), slowdown=rng.choice([1.0, 1.0, 1.0, 1.6, 2.5]),
                suspended=rng.random() < 0.1, owner=f"{team}_ADMIN"))
    out["tasks"] = tasks

    # Pipes: Snowpipe into the RAW schemas, some busy, some idle, some failing.
    pipes = []
    pid = 80000
    for team in rng.sample(TEAMS, 6):
        for k in range(rng.randint(1, 3)):
            pid += 1
            pipes.append(dict(id=pid, name=f"{team}_PIPE_{k + 1}", db=f"{team}_PROD_DB", schema="RAW", team=team,
                              files_per_day=rng.choice([0, 20, 200, 2000, 20000]), error_rate=rng.choice([0.0, 0.0, 0.02, 0.3])))
    out["pipes"] = pipes
    return out


# Per team: weekday weights Mon..Sun, a month-end factor (last 3 and first 2 days) and a trend
# (query volume today vs 130 days ago), so teams use the account differently.
TEAM_SHAPE = {
    "FINANCE": dict(week=[1.0, 1.0, 1.0, 1.0, 1.1, 0.1, 0.05], month_end=2.5, trend=1.0),
    "MARKETING": dict(week=[1.6, 1.1, 1.0, 1.0, 0.8, 0.2, 0.1], month_end=1.0, trend=0.7),
    "SALES": dict(week=[1.2, 1.1, 1.1, 1.0, 1.3, 0.05, 0.0], month_end=1.4, trend=1.2),
    "PLATFORM": dict(week=[1.0, 1.0, 1.0, 1.0, 1.0, 0.9, 0.9], month_end=1.0, trend=1.1),
    "DATA_SCIENCE": dict(week=[0.7, 1.3, 1.3, 1.2, 0.6, 0.3, 0.2], month_end=1.0, trend=2.2),
    "PRODUCT": dict(week=[1.0, 1.0, 1.0, 1.0, 0.7, 0.1, 0.1], month_end=1.0, trend=1.0),
    "RISK": dict(week=[1.0, 1.0, 1.0, 1.0, 1.0, 0.8, 0.8], month_end=1.3, trend=0.9),
    "OPS": dict(week=[0.8, 0.8, 0.8, 0.8, 0.8, 0.3, 0.3], month_end=1.0, trend=0.5),
}


def day_factor(team: str, day, back: int, span: int = 130) -> float:
    """Query volume multiplier for a team on a day `back` days before the as-of date."""
    s = TEAM_SHAPE.get(team) or TEAM_SHAPE["OPS"]
    f = s["week"][day.weekday()]
    if day.day <= 2 or day.day >= 27:
        f *= s["month_end"]
    t = max(0.0, min(1.0, 1 - back / span))          # 0 = oldest day, 1 = today
    return f * (1 + (s["trend"] - 1) * t) / ((1 + s["trend"]) / 2)   # the trend keeps the average level


def _warehouse_traits(whs: list[dict]) -> None:
    """Behaviour per warehouse: how busy, queuing, spill, oversized, created recently or dropped.

    activity  query volume vs its archetype (the base warehouse it is `like`)
    queue     share of queries that wait for a busy warehouse
    spill     share of big queries that spill
    fail      share of queries that fail
    oversized short, light queries on a big warehouse
    created_days / dropped_days  age; dropped ones are gone from SHOW WAREHOUSES
    cs_share  cloud services as a share of compute
    qas       query acceleration on
    constraint  RESOURCE_CONSTRAINT as SHOW WAREHOUSES and WAREHOUSE_EVENTS_HISTORY report it
    """
    rng = random.Random(f"{DEMO_SEED}:wh-traits")    # its own stream, so the catalog above stays put
    for w in whs:
        w.update(activity=round(rng.uniform(0.6, 1.4), 2), queue=0.0, spill=0.02,     # most rarely spill
                 fail=0.10 if w["like"] == "WH_ADHOC" else 0.03, oversized=False,
                 created_days=rng.randint(200, 900), dropped_days=None, qas=False,
                 cs_share=round(rng.uniform(0.02, 0.08), 3))
    by = {w["name"]: w for w in whs}
    over = dict(
        WH_SALES_BI=dict(queue=0.35, max=1, activity=2.2),                       # overloaded, cannot scale out
        WH_FINANCE_BI=dict(queue=0.25, max=1, activity=1.8),
        WH_MARKETING_BI=dict(queue=0.05, activity=1.0),
        WH_DATA_SCIENCE_ETL=dict(size="Small", spill=0.6, activity=1.5),         # undersized: spills
        WH_RISK_ETL=dict(spill=0.45, size="Medium"),
        WH_MARKETING_ADHOC=dict(size="2X-Large", oversized=True, activity=0.5, suspend=600),  # oversized for its work
        WH_PLATFORM_BI=dict(size="Large"),
        WH_PRODUCT_BI=dict(size="Medium", qas=True, max=3),
        WH_SALES_ETL=dict(size="X-Large", qas=True),
        WH_PLATFORM_ADHOC=dict(suspend=0, cs_share=0.16),                         # never suspends, metadata heavy
        WH_DBT_CI=dict(cs_share=0.14, activity=1.3),
        WH_FINANCE_DEV=dict(activity=0.4, created_days=20),                       # new this month
        WH_RISK_DEV=dict(activity=0.0, suspend=600),
        WH_OPS_BI=dict(size="X-Large", oversized=True, activity=0.4, max=1),
        WH_PRODUCT_ADHOC=dict(activity=0.03, suspend=3600),                       # almost idle, slow to suspend
        WH_OPS_ADHOC=dict(activity=0.0, suspend=1800),                            # idle
        WH_FINANCE_ADHOC=dict(fail=0.22),                                         # many failed queries
        WH_TEMP_MIGRATION=dict(like="WH_ETL", created_days=80, dropped_days=9, activity=1.6),
        WH_SANDBOX_GEN2=dict(created_days=12),
        WH_DS_FEATURES=dict(created_days=35, constraint="MEMORY_16X"),
        WH_PLATFORM_ETL=dict(size="3X-Large", activity=0.6),                      # the one very large warehouse
        WH_DS_TRAIN=dict(spill=0.5, constraint="MEMORY_64X"),                    # big-memory training
        WH_RISK_MODELS=dict(type="SNOWPARK-OPTIMIZED", constraint="MEMORY_1X_x86"),  # x86 libraries, small memory
        WH_REVERSE_ETL=dict(constraint="STANDARD_GEN_2"),                        # long-running Gen2
    )
    for w in whs:                                    # standard Gen1 unless set below
        w["constraint"] = "STANDARD_GEN_2" if "GEN2" in w["name"] else "STANDARD_GEN_1"
    for name, kv in over.items():
        if name in by:
            by[name].update(kv)


def team_of_warehouse(name: str) -> str | None:
    return next((w["team"] for w in catalog()["warehouses"] if w["name"] == name), None)
