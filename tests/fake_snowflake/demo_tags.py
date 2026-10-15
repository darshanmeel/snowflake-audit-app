"""Demo area "tags": the tag library, object and column tags, classification and query tags.

A governance schema holds the account's tags (COST_CENTER, TEAM, ENV, PROJECT, DATA_OWNER, PII, ...).
Catalog objects whose `tagged` flag is set carry most of those keys, with gaps: a key left off, a value
in the wrong case, a team that made its own CostCenter tag, schemas tagged where the database is not
(tables inherit, which TAG_REFERENCES never lists). Most PII tables carry the table-level PII tag; the
column tags and classification are demo_security's. COLUMNS lists every demo table's columns.
Query tags on the demo warehouses are rewritten for some teams to key=value pairs (team, cost_center).
"""
from __future__ import annotations

from tests.fake_snowflake.data import ACCOUNT_NAME

GOV_DB, GOV_SCHEMA, GOV_SCHEMA_ID = "PLATFORM_PROD_DB", "GOVERNANCE", 4990

PROJECTS = {"FINANCE": ["month_close", "forecasting", "audit_prep"],
            "MARKETING": ["campaign_attribution", "lead_scoring", "brand_tracker"],
            "SALES": ["pipeline_health", "quota_planning", "territory_map"],
            "PLATFORM": ["ingest_v2", "cost_controls", "dbt_migration", "observability"],
            "DATA_SCIENCE": ["churn_model", "price_elasticity", "feature_store"],
            "PRODUCT": ["usage_funnel", "experiments", "onboarding"],
            "RISK": ["fraud_signals", "credit_limits", "kyc_refresh"],
            "OPS": ["fulfilment", "support_queue", "inventory_sync"]}

PII_COLS = ["NAME", "EMAIL", "PHONE", "ADDRESS"]
PII_EXTRA = {"CUSTOMERS": ["BIRTH_DATE"], "PAYMENTS": ["CARD_NUMBER"], "CLAIMS": ["BIRTH_DATE"], "LEADS": ["POSTAL_CODE"]}
STEM_COLS = {"ORDERS": ["ORDER_ID", "CUSTOMER_ID", "AMOUNT", "CURRENCY"], "INVOICES": ["INVOICE_ID", "AMOUNT", "DUE_DATE"],
             "PAYMENTS": ["PAYMENT_ID", "AMOUNT", "METHOD", "CARD_LAST4"], "EVENTS": ["EVENT_ID", "EVENT_TYPE", "PAYLOAD"],
             "CAMPAIGNS": ["CAMPAIGN_ID", "CHANNEL", "BUDGET"], "LEDGER": ["ENTRY_ID", "ACCOUNT_CODE", "DEBIT", "CREDIT"],
             "CLAIMS": ["CLAIM_ID", "POLICY_ID", "AMOUNT", "REASON"], "FEATURES": ["ENTITY_ID", "FEATURE_SET", "VECTOR"]}


def add(b) -> None:
    w, cat, rng = b.w, b.cat, b.rng
    teams = cat["teams"]
    cc = cat["cost_centers"]
    people = {t: [u["name"] for u in cat["users"] if u["team"] == t and u["type"] == "PERSON"] for t in teams}
    assert GOV_SCHEMA_ID not in set(w.schema_id.values())
    db_id = {d["name"]: d["id"] for d in cat["databases"]}

    # ---- the tag library ---------------------------------------------------------------------------------------
    w.schema_id[(GOV_DB, GOV_SCHEMA)] = GOV_SCHEMA_ID
    b.au("SCHEMATA", schema_id=GOV_SCHEMA_ID, schema_name=GOV_SCHEMA, catalog_id=db_id[GOV_DB], catalog_name=GOV_DB,
         schema_owner="PLATFORM_ADMIN", retention_time=1, is_transient="NO", is_managed_access="YES",
         created=b.ts(620, 9), last_altered=b.ts(40, 9), owner_role_type="ROLE")
    tags: dict[str, dict] = {}

    def tag(tid, name, allowed=None, created=500, db=GOV_DB, schema=GOV_SCHEMA, schema_id=GOV_SCHEMA_ID,
            owner="PLATFORM_ADMIN", propagate=None, deleted=None):
        b.au("TAGS", tag_id=tid, tag_name=name, tag_schema_id=schema_id, tag_schema=schema, tag_database_id=db_id[db],
             tag_database=db, tag_owner=owner, tag_comment=None,             # the fake types TAG_COMMENT as JSON
             created=b.ts(created, 10),
             last_altered=b.ts(min(created, rng.randint(5, 200)), 10), deleted=b.ts(deleted, 10) if deleted else None,
             allowed_values=allowed, owner_role_type="ROLE", propagate=propagate,
             on_conflict="ALLOWED_VALUES_SEQUENCE" if propagate else None)
        tags[name] = dict(id=tid, db=db, schema=schema)

    tag(91001, "COST_CENTER", sorted(cc.values()), 610)
    tag(91002, "TEAM", None, 600)
    tag(91003, "ENV", ["prod", "dev", "test"], 600)
    tag(91004, "PROJECT", None, 420)
    tag(91005, "DATA_OWNER", None, 380)
    tag(91006, "PII", ["true", "false"], 300, propagate="ON_DEPENDENCY_AND_DATA_MOVEMENT")
    tag(91007, "SLA_TIER", ["gold", "silver", "bronze"], 200)
    tag(91008, "DATA_DOMAIN", None, 150)                                     # created, never used
    tag(91009, "OLD_BUDGET_CODE", None, 700, deleted=40)                     # dropped tag
    # Marketing made its own cost tag before the central one existed: a look-alike of COST_CENTER.
    mkt_schema = next(s for s in cat["schemas"] if s["db"] == "MARKETING_PROD_DB" and s["name"] == "MARTS")
    tag(91010, "CostCenter", None, 700, db="MARKETING_PROD_DB", schema="MARTS", schema_id=mkt_schema["id"],
        owner="MARKETING_ADMIN")

    def ref(name, value, domain, obj_name, obj_id, odb=None, osch=None, method="MANUAL", deleted=None):
        t = tags[name]
        b.au("TAG_REFERENCES", tag_database=t["db"], tag_schema=t["schema"], tag_id=t["id"], tag_name=name,
             tag_value=value, object_database=odb, object_schema=osch, object_id=obj_id, object_name=obj_name,
             object_deleted=deleted, domain=domain, column_id=None, column_name=None,
             apply_method=method)

    def team_value(team):
        r = rng.random()                                     # most use the agreed spelling, a few do not
        return team.title() if r < 0.08 else team.lower() if r < 0.12 else team

    def owner_of(team):
        return rng.choice(people[team]) if people[team] and rng.random() < 0.7 else f"{team}_ADMIN"

    def cost_key(team):
        return "CostCenter" if team == "MARKETING" else "COST_CENTER"

    # ---- warehouses --------------------------------------------------------------------------------------------
    for wh in cat["warehouses"]:
        team, deleted = wh["team"], (b.ts(wh["dropped_days"], 15) if wh.get("dropped_days") else None)
        put = lambda k, v, p: rng.random() < p and ref(k, v, "WAREHOUSE", wh["name"], wh["id"], deleted=deleted)
        if wh["tagged"]:
            put(cost_key(team), cc[team], 0.92)
            put("TEAM", team_value(team), 0.85)
            put("ENV", wh["env"], 0.8)
            put("PROJECT", rng.choice(PROJECTS[team]), 0.75)
            put("DATA_OWNER", owner_of(team), 0.8)
            if wh["env"] == "prod":
                put("SLA_TIER", rng.choice(["gold", "silver", "silver", "bronze"]), 0.6)
        else:                                                # partly tagged by hand, one key at a time
            put("TEAM", team_value(team), 0.35)
            put(cost_key(team), cc[team], 0.3)
            put("ENV", wh["env"], 0.25)

    # ---- databases, schemas (tables inherit), tables -------------------------------------------------------------
    db_tagged = {}
    for d in cat["databases"]:
        team = d["team"]
        db_tagged[d["name"]] = d["tagged"]
        put = lambda k, v, p: rng.random() < p and ref(k, v, "DATABASE", d["name"], d["id"])
        if d["tagged"]:
            put(cost_key(team), cc[team], 0.8)
            put("TEAM", team_value(team), 0.95)
            put("ENV", d["env"], 0.7)
            put("DATA_OWNER", owner_of(team), 0.55)
            put("PROJECT", rng.choice(PROJECTS[team]), 0.3)
        else:
            put("ENV", d["env"], 0.4)
    for s in cat["schemas"]:
        team = s["team"]
        put = lambda k, v, p: rng.random() < p and ref(k, v, "SCHEMA", s["name"], s["id"], odb=s["db"])
        if not db_tagged[s["db"]] and s["name"] in ("MARTS", "RAW"):
            put("TEAM", team_value(team), 0.6)               # tagged one level down instead of the database
            put("DATA_OWNER", owner_of(team), 0.5)
            put(cost_key(team), cc[team], 0.35)
        elif db_tagged[s["db"]]:
            put("DATA_OWNER", owner_of(team), 0.25)          # an override of what the database says
    for t in cat["tables"]:
        team = t["team"]
        method = "PROPAGATED" if rng.random() < 0.1 else "MANUAL"
        put = lambda k, v, p: rng.random() < p and ref(k, v, "TABLE", t["name"], t["id"], odb=t["db"], osch=t["schema"],
                                                       method=method)
        if t["tagged"]:
            put("DATA_OWNER", owner_of(team), 0.8)
            put("PROJECT", rng.choice(PROJECTS[team]).title() if rng.random() < 0.05 else rng.choice(PROJECTS[team]), 0.6)
            put("ENV", "dev" if t["transient"] else "prod", 0.3)
            put("TEAM", team_value(team), 0.4)
        if t["pii"] and rng.random() < 0.6:
            ref("PII", "true", "TABLE", t["name"], t["id"], odb=t["db"], osch=t["schema"])

    # ---- users and roles ---------------------------------------------------------------------------------------
    for u in cat["users"]:
        team = u["team"]
        put = lambda k, v, p: rng.random() < p and ref(k, v, "USER", u["name"], u["id"])
        if u["type"] == "PERSON":
            put("TEAM", team_value(team), 0.7)
            put(cost_key(team), cc[team], 0.45)
        else:
            put(cost_key(team), cc[team], 0.85)
            put("TEAM", team_value(team), 0.6)
            put("ENV", "prod", 0.7)
    for r in cat["roles"]:
        team = r["team"]
        put = lambda k, v, p: rng.random() < p and ref(k, v, "ROLE", r["name"], r["id"])
        if r["kind"] in ("READ", "WRITE", "ADMIN"):
            put(cost_key(team), cc[team], 0.55)
            put("TEAM", team_value(team), 0.8)
        elif r["kind"] == "SERVICE":
            put("COST_CENTER", cc["PLATFORM"], 0.6)

    # ---- tasks ---------------------------------------------------------------------------------------------------
    for tk in cat["tasks"]:
        team = tk["team"]
        put = lambda k, v, p: rng.random() < p and ref(k, v, "TASK", tk["name"], tk["id"], odb=tk["db"], osch=tk["schema"])
        put("TEAM", team_value(team), 0.5)
        put("PROJECT", rng.choice(PROJECTS[team]), 0.45)
        put("SLA_TIER", rng.choice(["gold", "silver", "bronze"]), 0.3)

    # ---- the account itself: defaults everything inherits. No COST_CENTER here: it would hide the untagged spend.
    for k, v in (("ENV", "prod"), ("DATA_OWNER", "PLATFORM_ADMIN")):
        ref(k, v, "ACCOUNT", ACCOUNT_NAME, None)

    _columns(b)
    _query_tags(b)


def _columns(b) -> None:
    """COLUMNS for the demo tables (the denominator of the classification checks). Column tags and
    classification on the PII columns come from demo_security, so the names here match its list."""
    rng = b.rng
    for t in b.cat["tables"]:
        stem = t["name"].rsplit("_", 1)[0]
        cols = ["ID"] + STEM_COLS.get(stem, ["NAME_CODE", "STATUS", "AMOUNT"])
        if t["pii"]:
            cols += PII_COLS + PII_EXTRA.get(stem, [])
        cols += ["REGION", "CREATED_AT", "UPDATED_AT", "LOADED_AT"] + [f"ATTR_{i:02d}" for i in range(rng.randint(2, 24))]
        for i, c in enumerate(dict.fromkeys(cols)):
            b.au("COLUMNS", table_catalog=t["db"], table_schema=t["schema"], table_name=t["name"], column_name=c,
                 data_type="NUMBER" if c in ("ID", "AMOUNT") or c.endswith("_ID") else
                 "TIMESTAMP_NTZ" if c.endswith(("_AT", "_DATE")) else "TEXT",
                 ordinal_position=i + 1, is_nullable="NO" if c == "ID" else "YES", kind="COLUMN")


def _query_tags(b) -> None:
    """Some teams set key=value query tags in their orchestrator and BI connections; the rest keep free text."""
    cat, rng = b.cat, b.rng
    cc = cat["cost_centers"]
    wh = {x["id"]: x for x in cat["warehouses"]}
    new: dict[str, str | None] = {}
    for row in b.w.rows.get(("account_usage", "QUERY_HISTORY"), []):
        x = wh.get(row.get("warehouse_id"))
        if x is None:
            continue
        team, tag, t = x["team"], row.get("query_tag") or "", x["team"].lower()
        out = tag
        if tag.startswith("airflow:"):
            dag = tag.split(":", 1)[1]
            if team in ("FINANCE", "PLATFORM", "RISK", "SALES"):
                out = f"team={t};cost_center={cc[team]};dag={dag}"
            elif team == "DATA_SCIENCE":
                out = f"team={t};dag={dag}"                                   # no cost center
            elif team == "MARKETING":
                out = f"Team=Marketing;cost_center={cc[team]};dag={dag}"      # other key and value spelling
        elif tag.startswith("bi:tableau:") and team in ("SALES", "FINANCE"):
            out = '{"tool":"tableau","dashboard":"%s","team":"%s","cost_center":"%s"}' % (tag.split(":")[2], t, cc[team])
        elif tag.startswith("ml:") and x["name"].startswith("WH_DS_"):
            out = f"team=data_science;cost_center={cc[team]};project={rng.choice(PROJECTS[team])}"
        elif not tag and x["like"] == "WH_ADHOC" and team in ("FINANCE", "PRODUCT") and rng.random() < 0.35:
            out = f"team={t};project={rng.choice(PROJECTS[team])}"
        if out != tag:
            row["query_tag"] = out or None
            new[row["query_id"]] = out or None
    for row in b.w.rows.get(("account_usage", "QUERY_ATTRIBUTION_HISTORY"), []):
        if row.get("query_id") in new:
            row["query_tag"] = new[row["query_id"]]
