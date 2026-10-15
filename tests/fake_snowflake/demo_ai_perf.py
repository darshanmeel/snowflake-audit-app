"""Demo AI, performance and storage-policy layer: who can call Cortex, AI credits on failed statements, container
services that can take internet traffic, storage lifecycle runs, and statement shapes that got slower.

Each part draws from its own random stream, so nothing the areas drew before changes.
- Cortex access: USE AI FUNCTIONS (Feb 2026) and SNOWFLAKE.CORTEX_USER still sit on PUBLIC, and the model allowlist
  is 'All': every user can call every model.
- AI on failed statements: the first label backfill on WH_DS_TRAIN (15 days back) was cancelled after three hours
  and re-run a week later; SVC_SALES_INGEST's contract-field extraction fails now and then when the AI output does
  not cast to a number; the SALES deal-notes app times out on a few long prompts. The tokens bill either way.
- BIND SERVICE ENDPOINT: granted to PUBLIC by the May 2026 rollout and revoked two weeks later, then granted to
  PRODUCT_ADMIN (its API and search backend face the internet) and to MARKETING_ADMIN for an uplift demo.
- Storage lifecycle: the ledger archive policy runs clean every day; the MARKETING 400-day expiry has failed for six
  days since a column in its expression was renamed; the RISK 7-year expiry failed once on a lost grant and recovered.
- Statement shapes (from demo_queries): the nightly MERGEs into the item-embeddings table that stopped pruning, a FINANCE
  dashboard whose date filter was widened and a feature build that now spills are slower in the last week; a SALES
  dashboard stays steady.
"""
from __future__ import annotations

import datetime as dt
import random

from tests.fake_snowflake import demo_entities
from tests.fake_snowflake.data import ACCOUNT_NAME as ACCT

GB = 1024 ** 3
SEARCH_STALE = ("POLICY_DOC_SEARCH", 23)          # Cortex Search service whose index stopped taking rows, days back
BIND_PUBLIC = (126, 112)                          # BIND SERVICE ENDPOINT on PUBLIC: granted, revoked (days back)
BIND_ROLES = [("PRODUCT_ADMIN", 112), ("MARKETING_ADMIN", 58)]
RECENT = 7                                        # the last days the shape layer makes slower


def _rng(part: str) -> random.Random:
    return random.Random(f"{demo_entities.DEMO_SEED}:ai-perf:{part}")


# ---- platform: called last from demo_platform.add -----------------------------------------------------------
def add_platform(p) -> None:
    b = p.b
    _ai_access(b)
    _spcs_bind(b)
    _failed_ai(p, _rng("failed"))
    _lifecycle(p, _rng("lifecycle"))


def _grant(b, privilege, on, name, grantee, created_k, deleted_k=None, by="ACCOUNTADMIN", catalog=None):
    b.au("GRANTS_TO_ROLES", created_on=b.ts(created_k, 10), modified_on=b.ts(deleted_k or created_k, 10),
         deleted_on=b.ts(deleted_k, 11) if deleted_k else None, privilege=privilege, granted_on=on, name=name,
         table_catalog=catalog, table_schema=None, granted_to="ROLE", grantee_name=grantee, grant_option=False,
         granted_by=by, granted_by_role_type="ROLE" if by else None, object_instance=None)


def _ai_access(b) -> None:
    # the defaults Snowflake set: granted by the system, so GRANTED_BY is empty
    _grant(b, "USE AI FUNCTIONS", "ACCOUNT", ACCT, "PUBLIC", (b.as_of - dt.date(2026, 2, 20)).days, by="")
    _grant(b, "USAGE", "DATABASE_ROLE", "SNOWFLAKE.CORTEX_USER", "PUBLIC", 700, by="", catalog="SNOWFLAKE")
    _grant(b, "USE AI FUNCTIONS", "ACCOUNT", ACCT, "DATA_SCIENCE_ADMIN", 150)
    b.show("parameters", key="CORTEX_MODELS_ALLOWLIST", value="All", default="All", level="",
           description="", type="STRING")


def _spcs_bind(b) -> None:
    granted, revoked = BIND_PUBLIC
    _grant(b, "BIND SERVICE ENDPOINT", "ACCOUNT", ACCT, "PUBLIC", granted, revoked, by="")
    for role, k in BIND_ROLES:
        _grant(b, "BIND SERVICE ENDPOINT", "ACCOUNT", ACCT, role, k)


# AI usage rows (by query tag) whose statements did not succeed: (tag, share of queries, error code, message)
FAILS = [
    ("job=contract_fields", 0.14, 100038, "Numeric value is not recognized"),
    ("app=deal_notes", 0.06, 630, "Statement reached its statement or warehouse timeout of 900 second(s) and was canceled."),
]


def _failed_ai(p, rng) -> None:
    b = p.b
    rows = b.w.rows.get(("account_usage", "CORTEX_AI_FUNCTIONS_USAGE_HISTORY"), [])
    users = {str(u["id"]): u for u in p.cat["users"]}
    whs = {w["id"]: w for w in b.w.wh}
    by_q: dict = {}
    for r in rows:
        by_q.setdefault(r["query_id"], []).append(r)
    picked = []
    for qid, rs in by_q.items():
        r0 = min(rs, key=lambda x: x["start_time"])
        k = (b.as_of - r0["start_time"].date()).days
        if k > 60:
            continue
        if r0["query_tag"] == "job=backfill_labels" and k == 15:
            picked.append((qid, rs, 604, "SQL execution canceled", "CREATE_TABLE_AS_SELECT"))
            continue
        for tag, share, code, msg in FAILS:
            if r0["query_tag"] == tag and rng.random() < share:
                picked.append((qid, rs, code, msg, "INSERT" if tag.startswith("job=") else "SELECT"))
    for n, (qid, rs, code, msg, qtype) in enumerate(sorted(picked)):
        r0 = min(rs, key=lambda x: x["start_time"])
        last = max(x["end_time"] for x in rs)
        start = r0["start_time"] + dt.timedelta(minutes=rng.randint(1, 40))
        end = max(start + dt.timedelta(minutes=rng.randint(3, 15)), last - dt.timedelta(minutes=rng.randint(1, 20)))
        if code == 630:
            end = start + dt.timedelta(seconds=900)
        ms = int((end - start).total_seconds() * 1000)
        u = users.get(str(r0["user_id"]), {})
        w = whs.get(r0["warehouse_id"], {})
        team = w.get("team") or u.get("team") or "DATA_SCIENCE"
        db = f"{team}_PROD_DB"
        b.au("QUERY_HISTORY", query_id=qid, query_text="ai function statement /* demo */", database_name=db,
             database_id=b.w.dbs.get(db), schema_name="MARTS", schema_id=b.w.schema_id.get((db, "MARTS")),
             query_type=qtype, user_name=u.get("name"), role_name=u.get("default_role"),
             warehouse_id=r0["warehouse_id"], warehouse_name=w.get("name"), warehouse_size=w.get("size"),
             warehouse_type=w.get("type"), cluster_number=1, query_tag=r0["query_tag"], execution_status="FAIL",
             error_code=code, error_message=msg, start_time=start, end_time=end, total_elapsed_time=ms,
             compilation_time=min(ms, rng.randint(200, 900)), execution_time=max(0, ms - 900),
             queued_provisioning_time=0, queued_repair_time=0, queued_overload_time=0, transaction_blocked_time=0,
             child_queries_wait_time=0, query_retry_time=0, fault_handling_time=0,
             bytes_scanned=int(rng.uniform(0.2, 3) * GB), rows_produced=0,
             credits_used_cloud_services=rng.uniform(0.0002, 0.002), query_hash=f"aiq{n % 7}",
             query_parameterized_hash=f"aiph-{r0['query_tag']}", query_hash_version=2,
             query_parameterized_hash_version=1, role_type="ROLE", user_type=u.get("type", "PERSON"),
             is_client_generated_statement=False)


def _lifecycle(p, rng) -> None:
    b = p.b
    tables = [t for t in b.w.tables if t.get("demo") and t["type"] == "BASE TABLE"]

    def biggest(db):
        ts = sorted((t for t in tables if t["db"] == db), key=lambda t: -(t["bytes"] or 0))
        return ts[0] if ts else None

    ledger = next((t for t in tables if t["db"] == "ARCHIVE_DB" and t["name"] == "GL_HISTORY"), None)
    plans = [  # id, name, table, created days back, action, options, failed days back (k), error code
        (48401, "SLP_ARCHIVE_LEDGER", ledger, 190, "ARCHIVE", {"ARCHIVE_TIER": "COOL", "ARCHIVE_FOR_DAYS": 365}, set(), None),
        (48402, "SLP_EXPIRE_400D", biggest("MARKETING_PROD_DB"), 240, "EXPIRE", {}, set(range(1, 7)), "000904"),
        (48403, "SLP_EXPIRE_7Y", biggest("RISK_PROD_DB"), 320, "EXPIRE", {}, {18}, "003001"),
    ]
    for pid, name, t, created, action, options, failed, code in plans:
        if t is None:
            continue
        db, schema = t["db"], t["schema"]
        b.au("STORAGE_LIFECYCLE_POLICIES", name=name, id=pid, schema_id=str(b.w.schema_id.get((db, schema))), schema=schema,
             database_id=str(b.w.dbs.get(db)), database=db, owner=f"{t.get('team') or 'FINANCE'}_ADMIN",
             signature="(EVENT_TS TIMESTAMP_NTZ)", return_type="BOOLEAN", body="<policy body>", comment=None,
             created_on=b.ts(created, 9), last_altered_on=b.ts(created, 9), deleted_on=None, options=options or None)
        b.au("POLICY_REFERENCES", policy_db=db, policy_schema=schema, policy_id=pid, policy_name=name,
             policy_kind="STORAGE_LIFECYCLE_POLICY", ref_database_name=db, ref_schema_name=schema,
             ref_entity_name=t["name"], ref_entity_domain="TABLE", policy_status="ACTIVE")
        for k in range(min(created, 95), 0, -1):
            start = b.ts(k, 0, rng.randint(5, 40))
            end = start + dt.timedelta(minutes=rng.randint(2, 25))
            bad = k in failed
            task = {"start_time": start.isoformat(), "end_time": end.isoformat(), "state": "FAILED" if bad else "SUCCEEDED",
                    "error_message_code": code if bad else None, "error_message": "<error>" if bad else None}
            if action == "ARCHIVE":
                task["rows_archived"] = 0 if bad else int(rng.uniform(2e5, 9e5))
            else:
                task["rows_expired"] = 0 if bad else int(rng.uniform(5e4, 4e5))
            b.au("STORAGE_LIFECYCLE_POLICY_HISTORY", policy_db=db, policy_schema=schema, policy_name=name,
                 ref_entity_db=db, ref_entity_schema=schema, ref_entity_name=t["name"], ref_entity_domain="TABLE",
                 state="FAILED" if bad else "SUCCEEDED", start_time=start, end_time=end,
                 execution_result={action: task}, policy_body="<policy body>")
            if pid != 48401:                      # the ledger policy's run credits are metered by demo_storage
                p.meter(k, 0, "STORAGE_LIFECYCLE_POLICY_EXECUTION", rng.uniform(0.01, 0.05), pid, name,
                        "STORAGE_LIFECYCLE_POLICY", db, schema, cs=0.0)


# ---- queries: called from demo_queries.add, before the sessions are flushed -------------------------------------
def add_shapes(g) -> None:
    """Statement shapes slower in the last RECENT days, on g's own random stream for the duration."""
    saved, g.rng = g.rng, _rng("shapes")
    try:
        _shapes(g)
    finally:
        g.rng = saved


def _shapes(g) -> None:
    from tests.fake_snowflake.demo_queries import GB as QGB, h
    # the tables demo_queries.pruning_views gave the worst pruning drops (its plan rows 5 and 2)
    tables = sorted([t for t in g.tables if t["type"] == "BASE TABLE" and (t["bytes"] or 0) > 20 * QGB],
                    key=lambda t: -t["bytes"])[:9]
    prune_t = next((tables[i] for i in (5, 2) if i < len(tables) and f"WH_{tables[i]['team']}_ETL" in g.wh), None)
    shapes = []   # wh, team, qtype, client, runs/day, hours, base s, recent s, kind, weekdays, (db, schema)
    if prune_t:
        team = prune_t["team"]
        shapes.append((f"WH_{team}_ETL", team, "MERGE", "airflow", 2, range(2, 6), 360, 950, "prune", False,
                       (prune_t["db"], prune_t["schema"])))
    shapes += [
        ("WH_FINANCE_BI", "FINANCE", "SELECT", "tableau", 4, range(8, 18), 12, 31, "data", True, (None, None)),
        ("WH_DATA_SCIENCE_ETL", "DATA_SCIENCE", "CREATE_TABLE_AS_SELECT", "airflow", 1, range(2, 6), 240, 720, "spill", False,
         (None, None)),
        ("WH_SALES_BI", "SALES", "SELECT", "looker", 5, range(8, 18), 14, 15, "steady", True, (None, None)),
    ]
    for wname, team, qtype, client, per_day, hours, base_s, recent_s, kind, weekdays, (db, schema) in shapes:
        if wname not in g.wh:
            continue
        ph = h("shape-regression", wname, kind)
        for k, d in g.days(90, weekdays=weekdays):
            if not g.alive(wname, k):
                continue
            recent = k <= RECENT
            users = [g.svc(team)] if client == "airflow" else g.people(team, k)
            if not users:
                continue
            for _ in range(per_day):
                secs = (recent_s if recent else base_s) * g.rng.uniform(0.85, 1.15)
                w = g.wh[wname]
                got = g.slot(w, d, hours, int(secs * 1000), shrink=False, tries=20)
                if not got:
                    # no attribution room left: still a run, in an hour the warehouse was billed
                    hr = g.rng.choice(list(hours))
                    start = dt.datetime(d.year, d.month, d.day, hr, g.rng.randint(0, 50), g.rng.randint(0, 59))
                    if not g.metered(w, start, int(secs * 1000)):
                        continue
                    got = (start, int(secs * 1000))
                start, ms = got
                parts = 40_000
                share = 0.18 if kind == "prune" and not recent else 0.62 if kind == "prune" else 0.25
                gb = (secs / 10) * (2.4 if kind == "data" and recent else 1.0)
                spill = int(g.rng.uniform(4, 8) * GB) if kind == "spill" and recent else 0
                g.q(wname, g.rng.choice(users), client, start, qtype, ms, phash=ph, qhash=h(ph, start),
                    ptotal=parts, pscanned=int(parts * share * g.rng.uniform(0.95, 1.05)), scanned=int(gb * GB),
                    remote=spill // 3, local=spill - spill // 3, comp_ms=g.rng.randint(150, 600),
                    rows=int(g.rng.uniform(1e3, 2e5)), db=db, schema=schema)
