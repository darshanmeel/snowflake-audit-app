"""Demo governance fit: data quality expectations, AI agents reading data, policy owners, unused table grants.

Called last from demo_platform.add, with its own random stream, so nothing before it draws different numbers.
- Expectations on the tables the data metric functions watch: most pass; CLAIMS_116's first test has failed
  every run for two weeks; one sales table broke two days ago; one DMF errors on its latest run; the
  expectation on the table whose DMF lost its table never runs.
- AI agents: SALES_COPILOT (a named Cortex Agent) answers sales questions from four SALES tables, one with a
  classified column no masking policy covers; data scientists call the agent REST API on their own tables; an
  external support agent (OAuth, marked agentic) reads OPS tables.
- Policy owners: the role that owns a classified finance table wrote its masking policy, and the owner of an
  OPS table its row access policy.
- Table grants: SALES_READ was given SELECT on every SALES and MARKETING table and reads none of the marketing
  ones; OPS_WRITE got INSERT, UPDATE and DELETE on every OPS table, and on every PLATFORM table for a migration
  that ended, which it never touches.
"""
from __future__ import annotations

import datetime as dt
import random

from tests.fake_snowflake import demo_entities

DAY = dt.timedelta(days=1)
COPILOT = "SALES_PROD_DB.AGENTS.SALES_COPILOT"
EXPECT = {"NULL_COUNT": "no_null_ids", "DUPLICATE_COUNT": "no_duplicate_keys", "FRESHNESS": "fresh_within_24h",
          "ROW_COUNT": "rows_loaded"}


def add(b) -> None:
    rng = random.Random(f"{demo_entities.DEMO_SEED}:gov-fit")
    w = b.w
    tables = {(t["table_catalog"], t["table_name"]): t for t in w.rows[("account_usage", "TABLES")]
              if t.get("deleted") is None and t.get("table_type") == "BASE TABLE"}
    _expectations(b, rng, tables)
    _agents(b, rng, tables)
    _owned_policies(b, tables)
    _table_grants(b, tables)


def _expectations(b, rng, tables) -> None:
    refs = [r for r in b.w.rows[("account_usage", "DATA_METRIC_FUNCTION_REFERENCES")] if r.get("level") == "TABLE"
            and r["metric_name"] in EXPECT and r["ref_database_name"].endswith("_PROD_DB")]
    # every expectation on the billed tables, then a few per database
    per_db: dict = {}
    keep = [r for r in refs if r["ref_entity_name"] in ("CLAIMS_116", "EVENTS_001", "CLICKS_045")
            or per_db.setdefault(r["ref_database_name"], []).append(r) or len(per_db[r["ref_database_name"]]) <= 5]
    for i, r in enumerate(keep):
        t = tables.get((r["ref_database_name"], r["ref_entity_name"]))
        name = EXPECT[r["metric_name"]]
        eid = f"EXP-{r['ref_id']}"
        b.au("DATA_METRIC_FUNCTION_EXPECTATIONS", metric_database_name="SNOWFLAKE", metric_schema_name="CORE",
             metric_name=r["metric_name"], argument_signature=r["argument_signature"], data_type="NUMBER",
             ref_database_name=r["ref_database_name"], ref_schema_name=r["ref_schema_name"],
             ref_entity_name=r["ref_entity_name"], ref_entity_domain="TABLE", ref_id=r["ref_id"],
             expectation_id=eid, expectation_name=name)
        if t is None or not str(r.get("schedule_status", "")).startswith("STARTED"):
            continue                                  # a suspended DMF: its expectation never runs
        # CLAIMS_116's first expectation has failed every run for two weeks
        first_claims = r["ref_entity_name"] == "CLAIMS_116" and not any(
            x["ref_entity_name"] == "CLAIMS_116" for x in keep[:i])
        fail_from = 14 if first_claims else (2 if i == 3 else None)
        for k in range(45, 0, -1):
            when = b.ts(k, 6, 15)
            violated = fail_from is not None and k <= fail_from
            if i == 7 and k == 1:
                violated = None                       # the DMF itself errored on its latest run
            elif not violated and rng.random() < 0.02:
                violated = True                       # a rare one-off failure that cleared the next day
            b.w.add("local", "DATA_QUALITY_MONITORING_EXPECTATION_STATUS", dict(
                scheduled_time=when, measurement_time=when + dt.timedelta(minutes=3), table_id=t["table_id"],
                table_name=t["table_name"], table_schema=t["table_schema"], table_database=t["table_catalog"],
                metric_name=r["metric_name"], metric_schema="CORE", metric_database="SNOWFLAKE",
                metric_return_type="NUMBER", reference_id=r["ref_id"], expectation_name=name, expectation_id=eid,
                expectation_violated=violated, value=None if violated is None else (rng.randint(3, 400) if violated else 0)))


def _sensitive_columns(b) -> dict:
    """{(db, table): [columns]} classified sensitive with no masking policy: not tagged PII (PII has a tag mask)
    and not masked directly."""
    pii = {(r["object_database"], r["object_name"], r["column_name"]) for r in b.w.rows[("account_usage", "TAG_REFERENCES")]
           if r.get("domain") == "COLUMN" and r.get("tag_name") == "PII"}
    pii |= {(r.get("ref_database_name"), r.get("ref_entity_name"), r.get("ref_column_name"))
            for r in b.w.rows[("account_usage", "POLICY_REFERENCES")] if r.get("ref_column_name")}
    out: dict = {}
    for r in b.w.rows[("account_usage", "TAG_REFERENCES")]:
        if (r.get("domain") == "COLUMN" and r.get("tag_database") == "SNOWFLAKE" and r.get("tag_name") == "PRIVACY_CATEGORY"
                and (r["object_database"], r["object_name"], r["column_name"]) not in pii):
            out.setdefault((r["object_database"], r["object_name"]), []).append(r["column_name"])
    return out


def _agents(b, rng, tables) -> None:
    sens = _sensitive_columns(b)
    users = demo_entities.catalog()["users"]
    sales_people = [u["name"] for u in users if u["team"] == "SALES" and u["type"] == "PERSON" and not u["disabled"]][:6]
    ds_people = [u["name"] for u in users if u["team"] == "DATA_SCIENCE" and u["type"] == "PERSON" and not u["disabled"]][:3]
    ext = next(u["name"] for u in users if u["team"] == "OPS" and u["type"] != "PERSON")

    def pick(db, n, want_sensitive=False):
        ts = sorted((t for (d, _), t in tables.items() if d == db), key=lambda t: t["table_id"])
        hot = [t for t in ts if (db, t["table_name"]) in sens]
        rest = [t for t in ts if (db, t["table_name"]) not in sens]
        return (hot[:1] + rest[:n - 1]) if want_sensitive else rest[:n]

    plans = [  # agent info, users, tables, queries per day
        ({"agentType": "CORTEX_AGENT", "agentId": COPILOT, "agentName": COPILOT}, sales_people,
         pick("SALES_PROD_DB", 4, True), 25),
        ({"agentType": "CORTEX_LITE_AGENT", "agentId": "/api/v2/cortex/agent:run", "agentName": None}, ds_people,
         pick("DATA_SCIENCE_PROD_DB", 3), 8),
        ({"agentType": "EXTERNAL_AGENT", "agentId": None, "agentName": None}, [ext], pick("OPS_PROD_DB", 2), 12),
    ]
    n = 0
    for info, who, tbls, per_day in plans:
        for k in range(1, 40):
            for _ in range(rng.randint(per_day // 2, per_day)):
                t = rng.choice(tbls)
                fqn = f"{t['table_catalog']}.{t['table_schema']}.{t['table_name']}"
                cols = [{"columnId": 1, "columnName": "ID"}, {"columnId": 2, "columnName": "UPDATED_AT"}]
                cols += [{"columnId": 3 + j, "columnName": c} for j, c in enumerate(sens.get((t["table_catalog"], t["table_name"]), [])[:2])]
                obj = [{"objectDomain": "Table", "objectName": fqn, "objectId": t["table_id"], "columns": cols}]
                n += 1
                b.au("ACCESS_HISTORY", query_id=f"01agt-{n:07d}", query_start_time=b.ts(k, rng.randint(8, 18), rng.randint(0, 59)),
                     user_name=rng.choice(who), direct_objects_accessed=obj, base_objects_accessed=obj, objects_modified=[],
                     policies_referenced=[], root_query_id=f"01agt-{n:07d}", agents_info=[info])


def _owned_policies(b, tables) -> None:
    """Two policies written by the role that owns the data they protect."""
    sens = _sensitive_columns(b)
    fin = next(t for (d, n), t in sorted(tables.items()) if d == "FINANCE_PROD_DB" and t.get("table_owner") and (d, n) in sens)
    ops = next(t for (d, n), t in sorted(tables.items()) if d == "OPS_PROD_DB" and t.get("table_owner")
               and (d, n) not in sens)
    created = dt.datetime.combine(b.as_of - 120 * DAY, dt.time(10))
    for pid, kind, view, name, owner, t, col in (
            (95001, "MASKING_POLICY", "MASKING_POLICIES", "MASK_IBAN_FINANCE", fin["table_owner"], fin, sens[(fin["table_catalog"], fin["table_name"])][0]),
            (95002, "ROW_ACCESS_POLICY", "ROW_ACCESS_POLICIES", "RAP_OPS_SITE", ops["table_owner"], ops, None)):
        row = dict(policy_id=pid, policy_name=name, policy_schema="SECURITY", policy_catalog=t["table_catalog"],
                   policy_owner=owner, owner_role_type="ROLE", policy_signature="(VAL VARCHAR)", policy_return_type="VARCHAR",
                   policy_body=None, policy_comment=None, created=created, last_altered=created, deleted=None)
        b.au(view, **row)
        b.au("POLICY_REFERENCES", policy_db=t["table_catalog"], policy_schema="SECURITY", policy_id=pid, policy_name=name,
             policy_kind=kind, ref_database_name=t["table_catalog"], ref_schema_name=t["table_schema"],
             ref_entity_name=t["table_name"], ref_entity_domain="TABLE", ref_column_name=col, policy_status="ACTIVE")


def _table_grants(b, tables) -> None:
    """Grants on every table of a team's databases, made long before the window."""
    when = dt.datetime.combine(b.as_of - 300 * DAY, dt.time(9))
    plans = [("SALES_READ", ("SALES_PROD_DB", "MARKETING_PROD_DB"), ("SELECT",)),
             ("FINANCE_READ", ("FINANCE_PROD_DB",), ("SELECT",)),
             ("OPS_WRITE", ("OPS_PROD_DB", "PLATFORM_PROD_DB"), ("INSERT", "UPDATE", "DELETE"))]
    for role, dbs, privs in plans:
        for (db, _), t in sorted(tables.items()):
            if db not in dbs:
                continue
            for p in privs:
                b.au("GRANTS_TO_ROLES", created_on=when, modified_on=when, deleted_on=None, privilege=p, granted_on="TABLE",
                     name=t["table_name"], table_catalog=db, table_schema=t["table_schema"], granted_to="ROLE",
                     grantee_name=role, grant_option=False, granted_by="SECURITYADMIN", granted_by_role_type="ROLE",
                     object_instance=None)
