"""Demo security area: admins, sign-ins, grants changing, PII tags, masking and row access policies, who reads PII.

Adds to the core demo users, roles, tables and queries; every draw comes from b.rng. Base rows change only in
_posture (the base admin fixture steps down), and only in the demo world.
Ids: users 59001+, roles 61001+, policies 9900-9979, credentials 7500+ (PATs 7590-7591, workload identity 7595,
MFA methods 7600+), events 70_000_000+.
"""
from __future__ import annotations

import datetime as dt
import json
import zlib

from tests.fake_snowflake.data import ACCOUNT_NAME
from tests.fake_snowflake.demo_pipelines import ALERTS, DTS, STREAMS
from tests.fake_snowflake.demo_tags import PII_EXTRA as TAGS_PII_EXTRA

ACCOUNTADMIN, SECURITYADMIN, USERADMIN, SYSADMIN = "ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN"
GOV_DB, GOV_SCHEMA, GOV_DB_ID, GOV_SCHEMA_ID = "GOV_DB", "POLICIES", 3, 7
PII_COLS = {"NAME": ("NAME", "IDENTIFIER"), "EMAIL": ("EMAIL", "IDENTIFIER"),
            "PHONE": ("PHONE_NUMBER", "IDENTIFIER"), "ADDRESS": ("STREET_ADDRESS", "IDENTIFIER")}
EXTRA_COLS = {"CUSTOMERS": [("BIRTH_DATE", "DATE_OF_BIRTH", "QUASI_IDENTIFIER"), ("GENDER", "GENDER", "QUASI_IDENTIFIER")],
              "PAYMENTS": [("CARD_NUMBER", "PAYMENT_CARD", "IDENTIFIER")],
              "CLAIMS": [("BIRTH_DATE", "DATE_OF_BIRTH", "QUASI_IDENTIFIER"), ("SSN", "US_SSN", "IDENTIFIER"),
                         ("AGE", "AGE", "QUASI_IDENTIFIER")],
              "LEADS": [("POSTAL_CODE", "POSTAL_CODE", "QUASI_IDENTIFIER"), ("IP_ADDRESS", "IP_ADDRESS", "IDENTIFIER")],
              "ACCOUNTS": [("ANNUAL_INCOME", "SALARY", "SENSITIVE")]}

# How each team protects its PII columns: direct masks, partial, via a tag, or not at all.
TEAM_PROTECTION = {"FINANCE": "direct", "RISK": "direct", "SALES": "partial", "DATA_SCIENCE": "tag_column",
                   "PLATFORM": "tag_table", "MARKETING": "none", "OPS": "none", "PRODUCT": "untagged"}
PAT_IDS = (7590, 7591)              # old token, then the one it was rotated to
WIF_ID = 7595


class _S:
    """Counters and shared lookups for one run."""

    def __init__(self, b):
        self.b, self.w, self.rng = b, b.w, b.rng
        self.event = 70_000_000
        self.qn = 0
        self.users = {u["name"]: u for u in b.cat["users"]}
        self.ip = {u: f"203.0.113.{10 + i}" for i, u in enumerate(b.w.users)}   # the IPs the core sign-ins use
        self.mfa: dict[str, tuple] = {}          # user -> (second factor, credential id)
        self.max_ok: dict[str, dt.datetime] = {}  # user -> latest successful sign-in written here
        self.cred_used: dict[int, dt.datetime] = {}
        self.cond_active: set = set()            # tables whose conditional mask works
        self.role_days: dict[str, int] = dict(getattr(b.w, "demo_role_days", {}))   # role -> created days ago
        self.now = dt.datetime.combine(b.as_of, dt.time(12))

    def next_event(self) -> int:
        self.event += 1
        return self.event


def _col_id(table: str, col: str) -> int:
    return zlib.crc32(f"{table}.{col}".encode()) % 100000


def add(b) -> None:
    s = _S(b)
    _users(s)
    _roles(s)
    _admin_grants(s)
    _role_grants(s)
    _object_grants(s)
    _mfa_methods(s)
    _mfa_factors(s)
    _logins(s)
    _network_policies(s)
    _auth_policies(s)
    pii = _tags_and_classification(s)
    _policies(s, pii)
    _queries(s, pii)
    _integrations(s)
    _secrets(s)
    _keys(s)
    _trust_center(s)
    _sync_last_login(s)
    _posture(s)


# ---- users ---------------------------------------------------------------------------------------------------------
NEW_USERS = [
    # name, type, team, default role, password, mfa, rsa, last login days, created days, extras
    ("BREAKGLASS_ADMIN", "PERSON", "PLATFORM", ACCOUNTADMIN, True, True, False, 25, 900, {}),     # tested monthly
    ("QA_TEST_USER", "PERSON", "PRODUCT", "PRODUCT_READ", True, False, False, None, 300, {}),
    ("EXT_CONTRACTOR_01", "PERSON", "OPS", "TEMP_CONTRACTOR_ROLE", True, False, False, 2, 150, {"expires": 10}),
    ("EXT_CONTRACTOR_02", "PERSON", "OPS", "TEMP_CONTRACTOR_ROLE", False, False, False, 100, 200, {"expires": 60}),
    ("TEO_HOLM", "PERSON", "PLATFORM", "PLATFORM_WRITE", True, True, False, 1, 700, {"secondary": "ALL"}),
    ("WREN_DORN", "PERSON", "SALES", "SALES_READ", True, False, False, 6, 400, {"locked": 1}),
    ("MILO_HOLM", "PERSON", "PLATFORM", "PLATFORM_ADMIN", True, True, False, 0, 800, {"secondary": "ALL"}),
    ("RIO_KERR", "PERSON", "FINANCE", "FINANCE_READ", True, True, False, 3, 250, {"bypass": 1, "secondary": "ALL"}),
    ("SVC_SFTP_LEGACY", "LEGACY_SERVICE", "OPS", "OPS_WRITE", True, None, False, 0, 1300, {}),
    ("SVC_DBT_PROD", "SERVICE", "PLATFORM", "PLATFORM_WRITE", False, None, True, 0, 600, {"pat": True}),
    ("TEO_VOSS", "PERSON", "MARKETING", "MARKETING_WRITE", True, False, False, 45, 700, {"deleted": 20}),
    ("ODA_BERG", None, "FINANCE", "FINANCE_READ", True, False, False, 60, 1600, {}),     # made before users had a TYPE
    ("ESME_LINDH", "PERSON", "RISK", "RISK_READ", True, True, False, 1, 500, {"duo": True}),
    ("NEO_HART", "PERSON", "SALES", "SALES_READ", True, False, False, None, 2, {"must_change": True}),
    ("SVC_DEPLOY_WIF", "SERVICE", "PLATFORM", "PLATFORM_WRITE", False, None, False, 0, 90, {"wif": True}),
]


def _users(s: _S) -> None:
    b = s.b
    for i, (name, typ, team, role, pw, mfa, rsa, last, created, x) in enumerate(NEW_USERS):
        person = typ in ("PERSON", None)                 # a NULL type behaves as a person
        b.au("USERS", user_id=59001 + i, name=name, login_name=name,
             email=f"{name.lower()}@example.com" if person else None, type=typ, disabled=False,
             snowflake_lock="locked" in x, has_password=pw, must_change_password=bool(x.get("must_change")),
             has_mfa=mfa if person else None, ext_authn_duo=bool(x.get("duo")), has_rsa_public_key=rsa,
             has_pat=bool(x.get("pat")), has_workload_identity=bool(x.get("wif")),
             bypass_mfa_until=b.ts(-x["bypass"], 18) if "bypass" in x else None,
             locked_until_time=b.ts(-x["locked"], 12) if "locked" in x else None,
             expires_at=b.ts(x["expires"], 0) if "expires" in x else None,
             last_success_login=b.ts(last, 9) if last is not None else None,
             password_last_set_time=_pw_set(b, created, s.rng.randint(30, 700)) if pw else None,
             created_on=b.ts(created, 10), deleted_on=b.ts(x["deleted"], 17) if "deleted" in x else None,
             owner="USERADMIN", default_role=role, default_secondary_role=x.get("secondary"),
             default_warehouse=f"WH_{team}_ADHOC", is_from_organization_user=False)
        s.users[name] = dict(name=name, type="PERSON" if typ is None else typ, team=team, default_role=role,
                             has_password=pw, has_mfa=mfa, has_rsa=rsa, last_login_days=last, created_days=created,
                             new=True, duo=bool(x.get("duo")), wif=bool(x.get("wif")), disabled=False)


def _pw_set(b, created: int, k: int) -> dt.datetime:
    """A password set k days ago, or with the user (created_on is 10:00) when k reaches back further."""
    return b.ts(k, 8) if k < created else b.ts(created, 10, 5)


EXTRA_ROLES = [
    # id, name, type, database (or app), owner, owner type, created days, deleted days, from an org user group
    (61001, "AMIR_NOOR_SANDBOX", "ROLE", None, USERADMIN, "ROLE", None, None, False),
    (61002, "RIO_MORA_ROLE", "ROLE", None, USERADMIN, "ROLE", None, None, False),
    (61003, "MARTS_READER", "DATABASE_ROLE", "FINANCE_PROD_DB", "FINANCE_ADMIN", "ROLE", 320, None, False),
    (61004, "PIPELINE_READER", "DATABASE_ROLE", "SALES_PROD_DB", "SALES_ADMIN", "ROLE", 210, None, False),
    (61005, "RAW_LOADER", "DATABASE_ROLE", "PLATFORM_PROD_DB", "PLATFORM_ADMIN", "ROLE", 160, None, False),
    (61006, "APP_VIEWER", "APPLICATION_ROLE", "DATA_APP_C", "DATA_APP_C", "APPLICATION", 150, None, False),
    (61008, "ORG_ANALYSTS", "ROLE", None, USERADMIN, "ROLE", 75, None, True),
]


def _roles(s: _S) -> None:
    """Personal roles, database roles per team database, an app role, a role dropped in the window, an org group."""
    b = s.b
    for rid, name, typ, db, owner, otype, created, deleted, org in EXTRA_ROLES:
        s.role_days[name] = created or s.rng.randint(200, 500)
        b.au("ROLES", role_id=rid, name=name, owner=owner, role_type=typ, role_database_name=db,
             owner_role_type=otype, created_on=b.ts(s.role_days[name], 9),
             deleted_on=b.ts(deleted, 11) if deleted else None, comment=None, is_from_organization_user_group=org)


def _gu(s: _S, user, role, created, deleted=None, by="USERADMIN") -> None:
    if role in s.role_days:                           # no grant before the role or the user existed
        created = min(created, max(s.role_days[role] - 1, deleted or 0))
    if user in s.users:
        created = min(created, s.users[user]["created_days"])
    s.b.au("GRANTS_TO_USERS", created_on=s.b.ts(created, s.rng.randint(8, 17), s.rng.randint(0, 59)),
           deleted_on=s.b.ts(deleted, s.rng.randint(8, 17)) if deleted is not None else None, role=role,
           granted_to="USER", grantee_name=user, granted_by=by)


def _gr(s: _S, privilege, on, name, grantee, created, deleted=None, by=SYSADMIN, catalog=None, schema=None,
        option=False, to="ROLE") -> None:
    if grantee in s.role_days:                        # no grant before its grantee role existed
        created = min(created, max(s.role_days[grantee] - 1, deleted or 0))
    s.b.au("GRANTS_TO_ROLES", created_on=s.b.ts(created, s.rng.randint(8, 18), s.rng.randint(0, 59)),
           modified_on=s.b.ts(deleted if deleted is not None else created, 9),
           deleted_on=s.b.ts(deleted, s.rng.randint(8, 18)) if deleted is not None else None, privilege=privilege,
           granted_on=on, name=name, table_catalog=catalog, table_schema=schema, granted_to=to,
           grantee_name=grantee, grant_option=option, granted_by=by, granted_by_role_type="ROLE",
           object_instance=None)


def _admin_grants(s: _S) -> None:
    """Admin role holders, plus admin roles granted and revoked inside the last 30 days."""
    old = lambda: s.rng.randint(120, 600)
    # long-standing holders: ACCOUNTADMIN stays at five holders with the base two
    for user, role in (("BREAKGLASS_ADMIN", ACCOUNTADMIN), ("SVC_OPS_INGEST", ACCOUNTADMIN),
                       ("IKE_BRANDT", SECURITYADMIN), ("JUNO_LUND", SECURITYADMIN), ("MILO_HOLM", SECURITYADMIN),
                       ("AMIR_QUILL", SECURITYADMIN), ("ELIF_NOOR", USERADMIN), ("MILO_ZANE", USERADMIN),
                       ("CHEN_TAMM", SYSADMIN), ("SVC_PLATFORM_INGEST", SYSADMIN), ("IKE_GRAY", SYSADMIN)):
        _gu(s, user, role, min(old(), s.users[user]["created_days"]), by=SECURITYADMIN)
    # changes in the window
    _gu(s, "AMIR_NOOR", ACCOUNTADMIN, 6, by=ACCOUNTADMIN)                 # a new ACCOUNTADMIN, password only
    _gu(s, "FARAH_FALK", USERADMIN, 12, by=SECURITYADMIN)
    _gu(s, "FARAH_JOST", SYSADMIN, 20, by=SECURITYADMIN)
    _gu(s, "GUS_GRAY", SECURITYADMIN, 10, deleted=2, by=ACCOUNTADMIN)     # temporary elevation, taken back
    _gu(s, "XAN_OSTA", ACCOUNTADMIN, 400, deleted=18, by=ACCOUNTADMIN)    # a stale admin cleaned up
    _gu(s, "SVC_RISK_INGEST", SYSADMIN, 25, by=SECURITYADMIN)
    # ordinary role changes in the window: people joining teams and the contractors
    for user, role, k in (("EXT_CONTRACTOR_01", "TEMP_CONTRACTOR_ROLE", 140), ("EXT_CONTRACTOR_01", "OPS_READ", 140),
                          ("EXT_CONTRACTOR_02", "TEMP_CONTRACTOR_ROLE", 190), ("QA_TEST_USER", "PRODUCT_READ", 300),
                          ("BREAKGLASS_ADMIN", "PLATFORM_READ", 900), ("WREN_DORN", "SALES_READ", 400),
                          ("MILO_HOLM", "PLATFORM_ADMIN", 700), ("RIO_KERR", "FINANCE_READ", 250),
                          ("SVC_SFTP_LEGACY", "OPS_WRITE", 1200), ("SVC_SFTP_LEGACY", "SVC_INGEST_ROLE", 1200),
                          ("SVC_DBT_PROD", "PLATFORM_WRITE", 600), ("SVC_DBT_PROD", "SVC_INGEST_ROLE", 600),
                          ("ZED_KERR", "OPS_ADMIN", 8), ("SANA_TAMM", "PRODUCT_WRITE", 15),
                          ("NIA_HOLM", "RISK_WRITE", 4), ("RIO_MORA", "RIO_MORA_ROLE", 300),
                          ("AMIR_NOOR", "AMIR_NOOR_SANDBOX", 500), ("ODA_BERG", "FINANCE_READ", 1500),
                          ("ESME_LINDH", "RISK_READ", 500), ("NEO_HART", "SALES_READ", 2),
                          ("SVC_DEPLOY_WIF", "PLATFORM_WRITE", 90)):
        _gu(s, user, role, k)
    # a leaver: removed 20 days ago, roles revoked the same day
    for role in ("MARKETING_WRITE", "MARKETING_READ"):
        _gu(s, "TEO_VOSS", role, 650, deleted=20)
    _gu(s, "TEO_VOSS", SYSADMIN, 300, deleted=20, by=SECURITYADMIN)
    # LEGACY_ETL_ROLE (its ROLES row is demo_pipelines'), dropped 11 days ago: its holders lose it the same day
    for user in ("OMAR_CRUZ", "BEA_FALK", "SVC_OPS_INGEST"):
        if user in s.users:
            _gu(s, user, "LEGACY_ETL_ROLE", min(600, s.users[user]["created_days"]), deleted=11)
    # roles that come from an organization user group
    for user in ("ELIF_NOOR", "GUS_CRUZ", "UMA_ROOS"):
        if user in s.users:
            _gu(s, user, "ORG_ANALYSTS", min(70, s.users[user]["created_days"]), by="GLOBALORGADMIN")
    # TEO_HOLM collects roles over the years: 21 granted straight to the user
    teams = s.b.cat["teams"]
    for role in [f"{t}_READ" for t in teams] + [f"{t}_WRITE" for t in teams] + [
            "SVC_REPORTING_ROLE", "SVC_ML_ROLE", "SVC_INGEST_ROLE", "AUDITOR_ROLE", SYSADMIN]:
        _gu(s, "TEO_HOLM", role, s.rng.randint(30, 690))
    for role in ("DATA_SCIENCE_WRITE", "SVC_ML_ROLE", "PRODUCT_READ", "MARKETING_READ", "RISK_READ", "SALES_READ",
                 "FINANCE_READ", "OPS_READ"):
        _gu(s, "RIO_MORA", role, s.rng.randint(40, 370))


def _role_grants(s: _S) -> None:
    """Account privileges, ownership moves, PUBLIC and grant-option grants, personal roles."""
    acct = ACCOUNT_NAME
    # in the window
    _gr(s, "MANAGE GRANTS", "ACCOUNT", acct, "PLATFORM_ADMIN", 4, by=SECURITYADMIN)
    _gr(s, "CREATE INTEGRATION", "ACCOUNT", acct, "DATA_SCIENCE_ADMIN", 9, by=ACCOUNTADMIN)
    _gr(s, "EXECUTE TASK", "ACCOUNT", acct, "FINANCE_WRITE", 16, by=ACCOUNTADMIN)
    _gr(s, "MONITOR USAGE", "ACCOUNT", acct, "SVC_REPORTING_ROLE", 300, deleted=7, by=ACCOUNTADMIN)
    _gr(s, "USAGE", "ROLE", USERADMIN, "AUDITOR_ROLE", 11, deleted=5, by=SECURITYADMIN)
    _gr(s, "OWNERSHIP", "ROLE", "TEMP_CONTRACTOR_ROLE", "OPS_ADMIN", 13, by=SECURITYADMIN)
    _gr(s, "OWNERSHIP", "INTEGRATION", "EAI_PAYMENTS_API", "PLATFORM_ADMIN", 21, by=ACCOUNTADMIN)
    _gr(s, "OWNERSHIP", "USER", "SVC_DBT_PROD", "PLATFORM_ADMIN", 26, by=USERADMIN)
    _gr(s, "CREATE DATABASE", "ACCOUNT", acct, "AMIR_NOOR_SANDBOX", 220, by=SYSADMIN)    # a personal role with an account privilege
    # SNOWFLAKE database roles: usage views opened wide
    _gr(s, "USAGE", "DATABASE_ROLE", "SNOWFLAKE.GOVERNANCE_VIEWER", "SVC_REPORTING_ROLE", 150, by=ACCOUNTADMIN)
    _gr(s, "USAGE", "DATABASE_ROLE", "SNOWFLAKE.SECURITY_VIEWER", "PLATFORM_READ", 90, by=ACCOUNTADMIN)

    tables = [t for t in s.b.cat["tables"] if t["type"] == "BASE TABLE"]
    by_schema: dict[tuple, list] = {}
    for t in tables:
        by_schema.setdefault((t["db"], t["schema"]), []).append(t)
    # PUBLIC: a database, a schema and a PII table opened to everyone; harmless function usage too
    _gr(s, "USAGE", "DATABASE", "MARKETING_PROD_DB", "PUBLIC", 240)
    _gr(s, "USAGE", "SCHEMA", "MARTS", "PUBLIC", 240, catalog="MARKETING_PROD_DB")
    pub = next((t for t in tables if t["db"] == "MARKETING_PROD_DB" and t["pii"]), tables[0])
    _gr(s, "SELECT", "TABLE", pub["name"], "PUBLIC", 3, catalog=pub["db"], schema=pub["schema"], by="MARKETING_ADMIN")
    _gr(s, "USAGE", "FUNCTION", "FMT_CURRENCY(NUMBER)", "PUBLIC", 300, catalog="FINANCE_PROD_DB", schema="MARTS")
    _gr(s, "USAGE", "WAREHOUSE", "WH_PRODUCT_ADHOC", "PUBLIC", 14, by="PRODUCT_ADMIN")
    # grant option outside the admin roles: FINANCE_ADMIN on its marts (PII), SVC_REPORTING_ROLE on sales marts
    for t in by_schema.get(("FINANCE_PROD_DB", "MARTS"), [])[:4]:
        _gr(s, "SELECT", "TABLE", t["name"], "FINANCE_ADMIN", 180, catalog=t["db"], schema=t["schema"], option=True)
    for t in by_schema.get(("SALES_PROD_DB", "STAGING"), [])[:3]:
        _gr(s, "SELECT", "TABLE", t["name"], "SVC_REPORTING_ROLE", 8, catalog=t["db"], schema=t["schema"], option=True)
    # schemas where many roles hand out access (not managed access)
    managed = {(x["db"], x["name"]) for x in s.b.cat["schemas"] if x["managed"]}
    spread = [k for k in by_schema if k not in managed and k[1] in ("MARTS", "STAGING")]
    for db, sch in spread[:5]:
        team = db.split("_PROD_DB")[0]
        for t in by_schema[(db, sch)][:4]:
            grantor = s.rng.choice([f"{team}_ADMIN", f"{team}_WRITE", SYSADMIN, "SVC_REPORTING_ROLE"])
            grantee = s.rng.choice([f"{team}_READ", "SVC_REPORTING_ROLE", "AUDITOR_ROLE", "DATA_SCIENCE_READ"])
            _gr(s, "SELECT", "TABLE", t["name"], grantee, s.rng.randint(5, 400), catalog=db, schema=sch, by=grantor)
    # admin roles owning data objects: maintenance procedures and stages left under ACCOUNTADMIN / SECURITYADMIN
    for k in range(14):
        kind = ["PROCEDURE", "FUNCTION", "STAGE", "FILE_FORMAT"][k % 4]
        _gr(s, "OWNERSHIP", kind, f"ADMIN_UTIL_{k + 1:02d}", ACCOUNTADMIN if k < 11 else SECURITYADMIN,
            s.rng.randint(60, 800), catalog="PLATFORM_PROD_DB", schema="STAGING", by=ACCOUNTADMIN)
    # personal roles: one owns a sandbox of functions, one collects SELECT grants
    for k in range(22):
        _gr(s, "OWNERSHIP", "FUNCTION" if k % 3 else "PROCEDURE", f"AN_SANDBOX_{k + 1:02d}", "AMIR_NOOR_SANDBOX",
            s.rng.randint(30, 400), catalog="PLATFORM_DEV_DB", schema="SCRATCH", by="AMIR_NOOR_SANDBOX")
    ds = [t for t in tables if t["team"] in ("DATA_SCIENCE", "PRODUCT")][:12]
    for t in ds:
        _gr(s, "SELECT", "TABLE", t["name"], "RIO_MORA_ROLE", s.rng.randint(20, 290), catalog=t["db"],
            schema=t["schema"], by=f"{t['team']}_ADMIN")
    _gr(s, "USAGE", "WAREHOUSE", "WH_DATA_SCIENCE_ADHOC", "RIO_MORA_ROLE", 290)

    # database roles: data access granted to the database role, the database role to account roles
    for db_role, db, holders in (("MARTS_READER", "FINANCE_PROD_DB", ("FINANCE_READ", "AUDITOR_ROLE")),
                                 ("PIPELINE_READER", "SALES_PROD_DB", ("SALES_READ", "SVC_REPORTING_ROLE")),
                                 ("RAW_LOADER", "PLATFORM_PROD_DB", ("SVC_INGEST_ROLE",))):
        sch = "RAW" if db_role == "RAW_LOADER" else "MARTS"
        _gr(s, "USAGE", "SCHEMA", sch, db_role, s.rng.randint(100, 200), catalog=db, by=f"{db.split('_PROD_DB')[0]}_ADMIN",
            to="DATABASE_ROLE")
        for t in by_schema.get((db, sch), [])[:5]:
            priv = "INSERT" if db_role == "RAW_LOADER" else "SELECT"
            _gr(s, priv, "TABLE", t["name"], db_role, s.rng.randint(20, 150), catalog=db, schema=sch,
                by=f"{t['team']}_ADMIN", to="DATABASE_ROLE")
        for h in holders:
            _gr(s, "USAGE", "DATABASE_ROLE", f"{db}.{db_role}", h, s.rng.randint(10, 150), catalog=db,
                by=f"{db.split('_PROD_DB')[0]}_ADMIN")
    _gr(s, "USAGE", "APPLICATION_ROLE", "DATA_APP_C.APP_VIEWER", "PRODUCT_READ", 140, by=ACCOUNTADMIN)
    # the role dropped 11 days ago: its grants go with it
    for wh in ("WH_OPS_ETL", "WH_PLATFORM_ETL"):
        _gr(s, "USAGE", "WAREHOUSE", wh, "LEGACY_ETL_ROLE", 650, deleted=11, by=SYSADMIN)
    _gr(s, "USAGE", "WAREHOUSE", "WH_FINANCE_BI", "ORG_ANALYSTS", 70, by=SYSADMIN)


def _object_grants(s: _S) -> None:
    """Ownership and operating privileges on the objects the other areas build: tasks, pipes, streams, dynamic
    tables, alerts, monitors, tags, policies, pools; plus MODIFY/MONITOR, APPLY and CREATE privileges."""
    cat, rng = s.b.cat, s.rng
    acct = ACCOUNT_NAME
    age = lambda: rng.randint(120, 600)
    for x in cat["tasks"]:
        _gr(s, "OWNERSHIP", "TASK", x["name"], x["owner"], age(), catalog=x["db"], schema=x["schema"], by=x["owner"])
        if x["root"] is None:
            _gr(s, "OPERATE", "TASK", x["name"], f"{x['team']}_WRITE", age(), catalog=x["db"], schema=x["schema"],
                by=x["owner"])
    for team in sorted({x["team"] for x in cat["tasks"] if x["warehouse"] is None}):
        _gr(s, "EXECUTE MANAGED TASK", "ACCOUNT", acct, f"{team}_ADMIN", age(), by=ACCOUNTADMIN)
    for x in cat["pipes"]:
        _gr(s, "OWNERSHIP", "PIPE", x["name"], f"{x['team']}_ADMIN", age(), catalog=x["db"], schema=x["schema"],
            by=f"{x['team']}_ADMIN")
        _gr(s, "MONITOR", "PIPE", x["name"], f"{x['team']}_READ", age(), catalog=x["db"], schema=x["schema"],
            by=f"{x['team']}_ADMIN")
    for i, (suffix, team, *_rest) in enumerate(STREAMS):
        _gr(s, "OWNERSHIP", "STREAM", f"S_{suffix}", f"{team}_ADMIN", 150 + i * 7, catalog=f"{team}_PROD_DB",
            schema="STAGING", by=f"{team}_ADMIN")
    for _tid, name, team, *_rest, story in DTS:
        _gr(s, "OWNERSHIP", "DYNAMIC_TABLE", name, f"{team}_ADMIN", 240, deleted=12 if story == "dropped" else None,
            catalog=f"{team}_PROD_DB", schema="MARTS", by=f"{team}_ADMIN")
        _gr(s, "SELECT", "DYNAMIC_TABLE", name, f"{team}_READ", 239, deleted=12 if story == "dropped" else None,
            catalog=f"{team}_PROD_DB", schema="MARTS", by=f"{team}_ADMIN")
    for _aid, name, team, *_rest in ALERTS:
        _gr(s, "OWNERSHIP", "ALERT", name, f"{team}_ADMIN", age(), catalog=f"{team}_PROD_DB", schema="MARTS",
            by=f"{team}_ADMIN")
    for t in cat["tables"]:
        if t["type"] == "MATERIALIZED VIEW":
            _gr(s, "OWNERSHIP", "MATERIALIZED_VIEW", t["name"], f"{t['team']}_ADMIN", t["created_days"],
                catalog=t["db"], schema=t["schema"], by=f"{t['team']}_ADMIN")
    _gr(s, "SELECT", "EXTERNAL_TABLE", "EXT_AD_SPEND", "MARKETING_READ", 190, catalog="MARKETING_PROD_DB", schema="RAW",
        by="MARKETING_ADMIN")
    _gr(s, "SELECT", "ICEBERG_TABLE", "ICE_TRAINING_EVENTS", "DATA_SCIENCE_READ", 170, catalog="DATA_SCIENCE_PROD_DB",
        schema="MARTS", by="DATA_SCIENCE_ADMIN")
    for team in ("FINANCE", "SALES", "OPS"):
        _gr(s, "OWNERSHIP", "SEQUENCE", f"{team}_ID_SEQ", f"{team}_ADMIN", age(), catalog=f"{team}_PROD_DB",
            schema="STAGING", by=f"{team}_ADMIN")
    # resource monitors: created by ACCOUNTADMIN, watched by the team admins
    for rm in sorted({w["monitor"] for w in cat["warehouses"] if w.get("monitor")}):
        _gr(s, "OWNERSHIP", "RESOURCE_MONITOR", rm, ACCOUNTADMIN, age(), by=ACCOUNTADMIN)
        _gr(s, "MONITOR", "RESOURCE_MONITOR", rm, f"{rm[3:]}_ADMIN", age(), by=ACCOUNTADMIN)
    # warehouses: team admins resize their own, readers watch the ETL ones
    for w in cat["warehouses"]:
        if w["name"] == f"WH_{w['team']}_ADHOC":
            _gr(s, "MODIFY", "WAREHOUSE", w["name"], f"{w['team']}_ADMIN", age(), by=SYSADMIN)
        if w["name"] == f"WH_{w['team']}_ETL":
            _gr(s, "MONITOR", "WAREHOUSE", w["name"], f"{w['team']}_READ", age(), by=SYSADMIN)
    _gr(s, "MODIFY", "WAREHOUSE", "WH_PRODUCT_BI", "PRODUCT_WRITE", 6, by="PRODUCT_ADMIN")        # in the window
    # tags in the governance schema, applied by the platform team
    for tag in ("COST_CENTER", "TEAM", "ENV", "PROJECT", "DATA_OWNER", "PII", "SLA_TIER", "DATA_DOMAIN"):
        _gr(s, "OWNERSHIP", "TAG", tag, "PLATFORM_ADMIN", age(), catalog="PLATFORM_PROD_DB", schema="GOVERNANCE",
            by="PLATFORM_ADMIN")
    for team in ("FINANCE", "DATA_SCIENCE", "PLATFORM"):
        _gr(s, "APPLY", "TAG", "COST_CENTER", f"{team}_ADMIN", age(), catalog="PLATFORM_PROD_DB", schema="GOVERNANCE",
            by="PLATFORM_ADMIN")
    _gr(s, "APPLY TAG", "ACCOUNT", acct, "PLATFORM_ADMIN", 400, by=ACCOUNTADMIN)
    _gr(s, "APPLY MASKING POLICY", "ACCOUNT", acct, "RISK_ADMIN", 350, by=ACCOUNTADMIN)
    _gr(s, "APPLY ROW ACCESS POLICY", "ACCOUNT", acct, "RISK_ADMIN", 300, by=ACCOUNTADMIN)
    _gr(s, "APPLY AUTHENTICATION POLICY", "ACCOUNT", acct, SECURITYADMIN, 300, by=ACCOUNTADMIN)
    # policies: security owns them
    for pid, name, _body, created in MASKS:
        _gr(s, "OWNERSHIP", "MASKING_POLICY", name, SECURITYADMIN, created, catalog=GOV_DB, schema=GOV_SCHEMA,
            by=SECURITYADMIN)
    _gr(s, "OWNERSHIP", "MASKING_POLICY", "MASK_RETIRED", SECURITYADMIN, 600, deleted=40, catalog=GOV_DB,
        schema=GOV_SCHEMA, by=SECURITYADMIN)
    for pid, name, _body, created in RAPS:
        _gr(s, "OWNERSHIP", "ROW_ACCESS_POLICY", name, SECURITYADMIN, created, catalog=GOV_DB, schema=GOV_SCHEMA,
            by=SECURITYADMIN)
    for _pid, name, _allowed, created in NETWORK_POLICIES:
        _gr(s, "OWNERSHIP", "NETWORK_POLICY", name, SECURITYADMIN, created, by=SECURITYADMIN)
    for name, *_rest in AUTH_POLICIES:
        _gr(s, "OWNERSHIP", "AUTHENTICATION_POLICY", name, SECURITYADMIN, 250, catalog=GOV_DB, schema=GOV_SCHEMA,
            by=SECURITYADMIN)
    # schemas: the writers create tables and views where they work
    for x in cat["schemas"]:
        if x["name"] in ("STAGING", "MARTS"):
            _gr(s, "CREATE TABLE", "SCHEMA", x["name"], f"{x['team']}_WRITE", age(), catalog=x["db"],
                by=f"{x['team']}_ADMIN")
        if x["name"] == "MARTS":
            _gr(s, "CREATE VIEW", "SCHEMA", x["name"], f"{x['team']}_WRITE", age(), catalog=x["db"],
                by=f"{x['team']}_ADMIN")
    # compute pools of the container services
    _gr(s, "OWNERSHIP", "COMPUTE_POOL", "POOL_ML", "DATA_SCIENCE_ADMIN", 260, by=ACCOUNTADMIN)
    _gr(s, "USAGE", "COMPUTE_POOL", "POOL_ML", "DATA_SCIENCE_WRITE", 250, by="DATA_SCIENCE_ADMIN")
    _gr(s, "OWNERSHIP", "COMPUTE_POOL", "POOL_APP", "PRODUCT_ADMIN", 200, by=ACCOUNTADMIN)
    _gr(s, "MONITOR", "COMPUTE_POOL", "POOL_APP", "PLATFORM_READ", 30, by="PRODUCT_ADMIN")


# ---- sign-ins ------------------------------------------------------------------------------------------------------
BAD_PW = (390100, "Incorrect username or password was specified.")
LOCKED = (390102, "User temporarily locked.")
JWT_BAD = (390144, "JWT token is invalid.")
OAUTH_EXPIRED = (390114, "Authentication token has expired.  The user must authenticate again.")
SAML_BAD = (390190, "There was an error related to the SAML Identity Provider account parameter. "
                    "Contact Snowflake support.")


def _np_blocked(ip: str) -> tuple:
    return 390422, (f"Incoming request with IP/Token {ip} is not allowed to access Snowflake. "
                    "Contact your account administrator.")


def _login(s: _S, user, when, ip, ok=True, first="PASSWORD", second=None, client="ui", error=None,
           session_open_hours=None, first_id=None, second_id=None, bound=True, closed=None) -> None:
    """One LOGIN_HISTORY row and, on success, its session. A success after the user's last sign-in day is dropped
    (bound) or later lifts USERS.LAST_SUCCESS_LOGIN (story events); nothing lands after the export time."""
    b = s.b
    if when >= s.now:
        when = s.now - dt.timedelta(minutes=s.rng.randint(5, 180))
    u = s.users.get(user)
    if ok and u is not None:
        last = u.get("last_login_days")
        if when.date() <= b.back(u["created_days"]):
            return                                             # before the user existed
        if bound:
            lim = b.ts(last, 9) if last is not None else None
            if lim is None or when.date() > lim.date():
                return
            if when > lim:
                when = lim - dt.timedelta(minutes=s.rng.randint(1, 90))
        if user not in s.max_ok or when > s.max_ok[user]:
            s.max_ok[user] = when
    if ok and first_id is not None and (first_id not in s.cred_used or when > s.cred_used[first_id]):
        s.cred_used[first_id] = when
    ctype, app_id, app = s.w.DEMO_CLIENTS[client]
    eid = s.next_event()
    code, msg = error or (None, None)
    b.au("LOGIN_HISTORY", event_id=eid, event_timestamp=when, event_type="LOGIN", user_name=user, client_ip=ip,
         reported_client_type=ctype, reported_client_version=app_id.split(" ")[-1], first_authentication_factor=first,
         second_authentication_factor=second if ok or error is None else None, is_success="YES" if ok else "NO",
         error_code=code, error_message=msg, connection=None, login_details=None,
         first_authentication_factor_id=str(first_id) if first_id is not None else None,
         second_authentication_factor_id=str(second_id) if second_id is not None and ok else None)
    if ok:
        is_open = session_open_hours is not None
        if closed is None and not is_open:
            closed = s.rng.choices(["LOGOUT", "ABANDONED", "FORCED_LOGOUT"], weights=[6, 3, 1])[0]
        b.au("SESSIONS", session_id=eid, created_on=when, user_name=user, authentication_method=first,
             login_event_id=eid, client_application_id=app_id,
             client_environment=json.dumps({"APPLICATION": app, "OS": "Linux", "OS_VERSION": "5.15"}),
             is_open="YES" if is_open else "NO", closed_reason=None if is_open else closed)


def _factors(s: _S, u) -> tuple:
    """(first factor, second factor, second factor credential id) for a user's sign-ins."""
    if u.get("wif"):
        return "WORKLOAD_IDENTITY", None, None
    if u.get("has_rsa"):
        return "RSA_KEYPAIR", None, None
    if not u.get("has_password"):
        return "SAML2_ASSERTION", None, None
    if u.get("duo"):
        return "PASSWORD", "DUO_PUSH", None                    # Duo factors have no credential row
    if u.get("has_mfa"):
        kind, cid = s.mfa.get(u["name"], ("TOTP", None))
        return "PASSWORD", kind, cid
    return "PASSWORD", None, None


def _mfa_methods(s: _S) -> None:
    """CREDENTIALS rows for enrolled MFA methods: TOTP for most, passkeys for a few."""
    b, rng = s.b, s.rng
    cid = 7600
    for n, u in s.users.items():
        if u["type"] != "PERSON" or not u.get("has_mfa") or u.get("duo") or not u.get("has_password"):
            continue
        cid += 1
        kind = "PASSKEY" if n in ("MILO_HOLM", "TEO_HOLM") or rng.random() < 0.12 else "TOTP"
        s.mfa[n] = (kind, cid)
        created = min(u["created_days"], rng.randint(30, 500))
        last = u.get("last_login_days")
        b.au("CREDENTIALS", credential_id=cid, name=f"{kind}_{n}", user_name=n, type=kind, domain="MFA_METHOD",
             status="ENROLLED", additional_details={"aaguid": f"00000000-0000-4000-8000-{cid:012d}"}
             if kind == "PASSKEY" else None, created_by=n, last_altered_by=n, created_on=b.ts(created, 9),
             last_used_on=b.ts(min(last, created), 9) if last is not None else None, last_altered=b.ts(created, 9))


def _mfa_factors(s: _S) -> None:
    """The core and compute sign-ins of enrolled users carry their method and credential id (TOTP or PASSKEY),
    as LOGIN_HISTORY documents, instead of a bare TOTP marker; Duo users carry DUO_PUSH."""
    for r in s.w.rows.get(("account_usage", "LOGIN_HISTORY"), []):
        if r.get("second_authentication_factor") not in ("MFA_TOTP", "TOTP"):
            continue
        name = r.get("user_name")
        if name in s.mfa:
            kind, cid = s.mfa[name]
            r["second_authentication_factor"] = kind
            r["second_authentication_factor_id"] = str(cid) if r.get("is_success") == "YES" else None
        elif s.users.get(name, {}).get("duo"):
            r["second_authentication_factor"], r["second_authentication_factor_id"] = "DUO_PUSH", None
        else:
            r["second_authentication_factor"] = "TOTP"          # base rows' old marker


def second_factor(w, user: str) -> tuple:
    """(second factor, credential id) of an MFA user, from the demo's USERS and CREDENTIALS rows."""
    for c in w.rows.get(("account_usage", "CREDENTIALS"), []):
        if c.get("user_name") == user and c.get("domain") == "MFA_METHOD" and c.get("status") == "ENROLLED":
            return c["type"], str(c["credential_id"])
    u = next((r for r in w.rows.get(("account_usage", "USERS"), []) if r.get("name") == user), {})
    return ("DUO_PUSH" if u.get("ext_authn_duo") else "TOTP"), None


def _logins(s: _S) -> None:
    b, rng = s.b, s.rng
    # password spraying: one IP tries a dozen user names in one night, two tries each
    spray = rng.sample([n for n, u in s.users.items() if u["type"] == "PERSON" and not u.get("new")], 9)
    for i, user in enumerate(spray + ["ADMIN", "SNOWFLAKE_ADMIN", "TEST"]):
        for k in range(2):
            _login(s, user, b.ts(5, 2, 3 * i + k), "192.0.2.201", ok=False, error=BAD_PW, client="snowsql")
    # a guessing burst that never gets in (WARN), a service on an expired password (WARN)
    for k in range(14):
        _login(s, "HANA_WEIR", b.ts(3, 1, 2 + 3 * k), "192.0.2.210", ok=False, error=BAD_PW)
    ip = s.ip.get("SVC_MARKETING_INGEST", "203.0.113.200")
    for d in range(1, 10):
        for k in range(2):
            _login(s, "SVC_MARKETING_INGEST", b.ts(d, 8 * k, 15), ip, ok=False, error=BAD_PW, client="airflow")
    # a lockout, and a handful of everyday typos
    for k in range(5):
        _login(s, "WREN_DORN", b.ts(1, 8, 40 + k), "198.51.100.140", ok=False, error=BAD_PW)
    _login(s, "WREN_DORN", b.ts(1, 8, 46), "198.51.100.140", ok=False, error=LOCKED)
    for user in rng.sample([n for n, u in s.users.items() if u["type"] == "PERSON" and u.get("has_password")
                            and not u.get("new") and (u["last_login_days"] or 99) < 25], 14):
        d = rng.randint(max(1, s.users[user]["last_login_days"] or 1), 28)
        for k in range(rng.choice([1, 1, 2, 3, 6])):
            _login(s, user, b.ts(d, 9, k), s.ip.get(user, "203.0.113.250"), ok=False, error=BAD_PW)
    # a service key rotated without its new public key: JWTs rejected for three days, then fixed
    rsa_svc = [n for n, u in s.users.items() if u["type"] != "PERSON" and u.get("has_rsa") and not u.get("new")]
    if rsa_svc:
        user = rsa_svc[0]
        for d in (6, 5, 4):
            for k in range(rng.randint(4, 8)):
                _login(s, user, b.ts(d, k % 24, rng.randint(0, 59)), s.ip.get(user, "203.0.113.200"), ok=False,
                       first="RSA_KEYPAIR", error=JWT_BAD, client="airflow")
        _login(s, user, b.ts(4, 16, 5), s.ip.get(user, "203.0.113.200"), first="RSA_KEYPAIR", client="airflow")
    # SSO sign-ins failing on the IdP side for a person without a password
    sso = [n for n, u in s.users.items() if u["type"] == "PERSON" and not u.get("has_password") and not u.get("new")
           and (u["last_login_days"] or 99) < 20]
    for user in sso[:2]:
        for k in range(rng.randint(2, 5)):
            _login(s, user, b.ts(rng.randint(2, 15), 8, 10 + k), s.ip.get(user, "203.0.113.250"), ok=False,
                   first="SAML2_ASSERTION", error=SAML_BAD)
    # a contractor tries from home, outside NP_CONTRACTORS
    for d in (3, 2):
        for k in range(rng.randint(3, 6)):
            _login(s, "EXT_CONTRACTOR_01", b.ts(d, 19, 5 * k), "198.51.100.170", ok=False,
                   error=_np_blocked("198.51.100.170"))

    # admins: daily sign-ins with their own habits; a few sessions left open
    admins = {
        "IKE_BRANDT": dict(ips=["10.20.1.11"], hours=(8, 18), every=1),
        "JUNO_LUND": dict(ips=["10.20.1.12"], hours=(8, 18), every=2, open_hours=30),
        "AMIR_NOOR": dict(ips=[s.ip.get("AMIR_NOOR", "203.0.113.60")], hours=(7, 20), every=1, open_hours=200,
                          since=6),
        "MILO_HOLM": dict(ips=["10.20.1.14"], hours=(22, 30), every=1),               # mostly at night (UTC)
        "ELIF_NOOR": dict(ips=[f"10.20.{k}.15" for k in range(1, 8)], hours=(8, 18), every=1),
        "FARAH_FALK": dict(ips=[s.ip.get("FARAH_FALK", "203.0.113.61")], hours=(9, 17), every=2, since=12),
        "BREAKGLASS_ADMIN": dict(ips=["10.20.9.9"], hours=(9, 10), every=30, since=115),   # the monthly test
    }
    for user, p in admins.items():
        u = s.users[user]
        first, second, sid = _factors(s, u)
        if p["every"] == 0:
            continue
        for d in range(p.get("since", 29), 0, -p["every"]):
            h = rng.randint(*p["hours"])
            day = d - 1 if h >= 24 else d                      # past midnight is the next day
            _login(s, user, b.ts(day, h % 24, rng.randint(0, 59)), rng.choice(p["ips"]), first=first, second=second,
                   second_id=sid, client=rng.choice(["ui", "ui", "snowsql"]))
        if "open_hours" in p:
            when = dt.datetime.combine(b.as_of, dt.time(0)) - dt.timedelta(hours=p["open_hours"])
            _login(s, user, when, p["ips"][0], first=first, second=second, second_id=sid,
                   session_open_hours=p["open_hours"], bound=False)
    # the new ACCOUNTADMIN is also being guessed at
    for k in range(12):
        _login(s, "AMIR_NOOR", b.ts(rng.randint(1, 20), rng.randint(0, 5), k), "192.0.2.220", ok=False, error=BAD_PW)

    # new users' own sign-ins; SVC_DBT_PROD uses its PATs (rotated 25 days ago), SVC_DEPLOY_WIF its cloud identity
    for user in ("EXT_CONTRACTOR_01", "TEO_HOLM", "RIO_KERR", "SVC_SFTP_LEGACY", "SVC_DBT_PROD", "WREN_DORN",
                 "ODA_BERG", "ESME_LINDH", "SVC_DEPLOY_WIF"):
        u = s.users[user]
        first, second, sid = _factors(s, u)
        if user == "SVC_DBT_PROD":
            first = "PROGRAMMATIC_ACCESS_TOKEN"
        client = {"SVC_DBT_PROD": "dbt", "SVC_SFTP_LEGACY": "snowsql", "SVC_DEPLOY_WIF": "terraform"}.get(user)
        step = 1 if u["type"] != "PERSON" else rng.choice([1, 2, 3])
        for d in range(max(u["last_login_days"] or 0, 0), 120, step):
            if user == "EXT_CONTRACTOR_01" and d > 40:
                break
            fid = (PAT_IDS[1] if d < 25 else PAT_IDS[0]) if user == "SVC_DBT_PROD" else (
                WIF_ID if user == "SVC_DEPLOY_WIF" else None)
            _login(s, user, b.ts(d, rng.randint(7, 19), rng.randint(0, 59)), f"10.30.{len(user)}.{d % 3 + 2}",
                   first=first, second=second, second_id=sid, first_id=fid,
                   client=client or rng.choice(["ui", "ui", "dbeaver"]))
    # every new user's last sign-in, at the time USERS reports it
    for name, typ, *_rest in NEW_USERS:
        u = s.users[name]
        if u["last_login_days"] is None:
            continue
        first, second, sid = _factors(s, u)
        fid = None
        if name == "SVC_DBT_PROD":
            first, fid = "PROGRAMMATIC_ACCESS_TOKEN", PAT_IDS[1]
        elif name == "SVC_DEPLOY_WIF":
            fid = WIF_ID
        client = "dbt" if name == "SVC_DBT_PROD" else ("airflow" if u["type"] != "PERSON" else "ui")
        _login(s, name, b.ts(u["last_login_days"], 9), f"10.30.{len(name)}.2", first=first, second=second,
               second_id=sid, first_id=fid, client=client, closed="DROP_USER" if name == "TEO_VOSS" else None)

    # new sources in the window for users with a history: travel (OK), a service (WARN), an admin (WARN)
    for user, ip in (("JUNO_LUND", "198.51.100.161"), ("SVC_RISK_INGEST", "198.51.100.162"),
                     ("UMA_ROOS", "198.51.100.163"), ("KAI_FALK", "198.51.100.164"), ("ZED_KERR", "198.51.100.165"),
                     ("SVC_PRODUCT_INGEST", "198.51.100.166")):
        u = s.users[user]
        first, second, sid = _factors(s, u)
        client = "ui" if u["type"] == "PERSON" else "airflow"
        lo = max(1, u["last_login_days"] or 1)
        for d in rng.sample(range(lo, max(lo + 3, 12)), 3):
            _login(s, user, b.ts(d, rng.randint(6, 22), rng.randint(0, 59)), ip, first=first, second=second,
                   second_id=sid, client=client)
    # BI users through an OAuth client; two of them hit an expired token first
    bi = rng.sample([n for n, u in s.users.items() if u["type"] == "PERSON" and not u.get("new")
                     and (u["last_login_days"] or 99) < 10], 6)
    for i, user in enumerate(bi):
        lo = max(1, s.users[user]["last_login_days"] or 1)
        days = rng.sample(range(lo, 28), 4)
        for d in days:
            when = b.ts(d, rng.randint(8, 17), rng.randint(0, 59))
            if i < 2 and d == min(days):
                for k in range(rng.randint(1, 3)):
                    _login(s, user, when - dt.timedelta(minutes=3 - k), s.ip.get(user, "203.0.113.250"), ok=False,
                           first="OAUTH_ACCESS_TOKEN", error=OAUTH_EXPIRED, client="tableau")
            _login(s, user, when, s.ip.get(user, "203.0.113.250"), first="OAUTH_ACCESS_TOKEN", client="tableau")


def _sync_last_login(s: _S) -> None:
    """USERS.LAST_SUCCESS_LOGIN follows the story sign-ins written here when they are later."""
    for row in s.w.rows.get(("account_usage", "USERS"), []):
        when = s.max_ok.get(row["name"])
        if when is not None and row.get("deleted_on") is None and (
                row.get("last_success_login") is None or when > row["last_success_login"]):
            row["last_success_login"] = when


ADMIN_ROLES = (ACCOUNTADMIN, SECURITYADMIN, USERADMIN, SYSADMIN)


def _posture(s: _S) -> None:
    """The base account's admin fixture stepped down before the window and the people holding admin roles changed
    their passwords this year, so the admin stories are the demo's own (the new password-only ACCOUNTADMIN, the
    admins nobody has seen for months) and most user checks read OK or WARN."""
    b, w = s.b, s.w
    for r in w.rows.get(("account_usage", "GRANTS_TO_USERS"), []):
        if r["grantee_name"] == "ADMIN_BOB" and r["role"] in ADMIN_ROLES and r.get("deleted_on") is None:
            r["deleted_on"] = b.ts(40, 10)
    _gu(s, "ADMIN_BOB", "PLATFORM_READ", 40, by=SECURITYADMIN)
    holders = {r["grantee_name"] for r in w.rows.get(("account_usage", "GRANTS_TO_USERS"), [])
               if r["role"] in ADMIN_ROLES and r.get("deleted_on") is None}
    for r in w.rows.get(("account_usage", "USERS"), []):
        if r["name"] == "ADMIN_BOB":
            r["default_role"] = "PLATFORM_READ"
        elif (r["name"] in holders and r["name"] != "AMIR_NOOR" and r.get("has_password")
              and r.get("type") == "PERSON" and r.get("deleted_on") is None):
            r["password_last_set_time"] = b.ts(s.rng.randint(15, 160), 8)
    # the base fixture's failure burst on one IP stays under the CRITICAL count
    key = ("account_usage", "LOGIN_HISTORY")
    burst = [r for r in w.rows.get(key, []) if r["user_name"] == "ADMIN_BOB" and r.get("client_ip") == "192.0.2.99"
             and r["is_success"] == "NO"]
    drop = {id(r) for r in burst[15:]}
    if drop:
        w.rows[key] = [r for r in w.rows[key] if id(r) not in drop]


NETWORK_POLICIES = [(9970, "NP_SERVICE_USERS", "10.40.0.0/16,10.41.0.0/16", 300),
                    (9971, "NP_ADMIN_VPN", "10.20.0.0/16", 200),
                    (9972, "NP_PARTNER_OLD", "198.51.100.0/24", 500),
                    (9973, "NP_CONTRACTORS", "10.30.0.0/16", 5)]


def _network_policies(s: _S) -> None:
    b = s.b
    for pid, name, allowed, age in NETWORK_POLICIES:
        b.au("NETWORK_POLICIES", id=pid, name=name, owner=SECURITYADMIN, owner_role_type="ROLE", comment=None,
             created=b.ts(age, 9), last_altered=b.ts(min(age, 30), 9), allowed_ip_list=allowed, blocked_ip_list="")
    svc = [n for n, u in s.users.items() if u["type"] != "PERSON"]
    for user in svc[: len(svc) - 4]:                  # a few service users are left on the account policy
        b.au("POLICY_REFERENCES", policy_db=None, policy_schema=None, policy_id=9970, policy_name="NP_SERVICE_USERS",
             policy_kind="NETWORK_POLICY", ref_entity_name=user, ref_entity_domain="USER", policy_status="ACTIVE")
    for user in ("IKE_BRANDT", "JUNO_LUND", "ELIF_NOOR", "MILO_HOLM"):
        b.au("POLICY_REFERENCES", policy_db=None, policy_schema=None, policy_id=9971, policy_name="NP_ADMIN_VPN",
             policy_kind="NETWORK_POLICY", ref_entity_name=user, ref_entity_domain="USER", policy_status="ACTIVE")
    for user in ("EXT_CONTRACTOR_01", "EXT_CONTRACTOR_02"):
        b.au("POLICY_REFERENCES", policy_db=None, policy_schema=None, policy_id=9973, policy_name="NP_CONTRACTORS",
             policy_kind="NETWORK_POLICY", ref_entity_name=user, ref_entity_domain="USER", policy_status="ACTIVE")


AUTH_POLICIES = [
    # name, options text, set on
    ("AP_SSO_FIRST", '{"MFA_ENROLLMENT":"REQUIRED_PASSWORD_ONLY","AUTHENTICATION_METHODS":["SAML","PASSWORD"],'
                     '"PAT_POLICY":{"MAX_EXPIRY_IN_DAYS":60,"NETWORK_POLICY_EVALUATION":"ENFORCED_REQUIRED",'
                     '"REQUIRE_ROLE_RESTRICTION_FOR_SERVICE_USERS":true}}', None),
    ("AP_SERVICE_PAT", '{"AUTHENTICATION_METHODS":["PROGRAMMATIC_ACCESS_TOKEN","KEYPAIR"],'
                       '"PAT_POLICY":{"MAX_EXPIRY_IN_DAYS":90,"NETWORK_POLICY_EVALUATION":"ENFORCED_REQUIRED",'
                       '"REQUIRE_ROLE_RESTRICTION_FOR_SERVICE_USERS":false}}', "USER"),
]


def _auth_policies(s: _S) -> None:
    """Two more authentication policies: an SSO-first one that reads clean, a service one that lets tokens skip
    the role restriction."""
    for name, options, set_on in AUTH_POLICIES:
        s.b.show("authentication_policies", created_on=s.b.ts(250, 9), name=name, database_name=GOV_DB,
                 schema_name=GOV_SCHEMA, kind="AUTHENTICATION_POLICY", owner=SECURITYADMIN, comment=None,
                 owner_role_type="ROLE", options=options, set_on=set_on)


# ---- PII: tags, classification, policies ---------------------------------------------------------------------------
def _pii_columns(t) -> list[tuple]:
    stem = t["name"].rsplit("_", 1)[0]
    return [(c, sem, priv) for c, (sem, priv) in PII_COLS.items()] + EXTRA_COLS.get(stem, [])


CLASSIFY_ERRORS = ["Insufficient privileges to operate on table.", "Statement reached its statement or warehouse "
                   "timeout of 3600 second(s) and was canceled.", "Object does not exist or not authorized."]


def _tags_and_classification(s: _S) -> list[dict]:
    """System tags on PII columns where the team applied them, and the classification results behind them."""
    b, rng = s.b, s.rng
    pii = [t for t in b.cat["tables"] if t["pii"]]
    for t in pii:
        mode = TEAM_PROTECTION[t["team"]]
        cols = _pii_columns(t)
        # columns demo_tags does not list for this table: their COLUMNS rows are added here
        stem = t["name"].rsplit("_", 1)[0]
        for i, (col, _sem, _priv) in enumerate(c for c in cols if c[0] not in PII_COLS
                                                and c[0] not in TAGS_PII_EXTRA.get(stem, [])):
            b.au("COLUMNS", table_catalog=t["db"], table_schema=t["schema"], table_name=t["name"], column_name=col,
                 data_type="NUMBER" if col in ("AGE", "ANNUAL_INCOME") else "TEXT", ordinal_position=200 + i,
                 is_nullable="YES", kind="COLUMN")
        if mode != "untagged":
            for col, sem, priv in cols:
                if mode == "partial" and col == "ADDRESS" and rng.random() < 0.5:
                    continue                                  # classification never ran on some columns
                for tag, val in (("SEMANTIC_CATEGORY", sem), ("PRIVACY_CATEGORY", priv)):
                    b.au("TAG_REFERENCES", tag_database="SNOWFLAKE", tag_schema="CORE", tag_id=None, tag_name=tag,
                         tag_value=val, object_database=t["db"], object_schema=t["schema"], object_id=t["id"],
                         object_name=t["name"], domain="COLUMN", column_id=_col_id(t["name"], col), column_name=col,
                         apply_method="CLASSIFIED" if t["team"] != "OPS" else "MANUAL")
        if mode == "tag_column":
            for col, _sem, priv in cols:
                if priv == "IDENTIFIER":
                    b.au("TAG_REFERENCES", tag_database="GOV_DB", tag_schema="TAGS", tag_id=9301, tag_name="PII",
                         tag_value="true", object_database=t["db"], object_schema=t["schema"], object_id=t["id"],
                         object_name=t["name"], domain="COLUMN", column_id=_col_id(t["name"], col), column_name=col,
                         apply_method="MANUAL")
        if mode == "tag_table":
            b.au("TAG_REFERENCES", tag_database="GOV_DB", tag_schema="TAGS", tag_id=9301, tag_name="PII",
                 tag_value="true", object_database=t["db"], object_schema=t["schema"], object_id=t["id"],
                 object_name=t["name"], domain="TABLE", apply_method="MANUAL")
        # classification: every team but OPS ran it on its PII tables
        if t["team"] == "OPS":
            continue
        res = {"ID": {"recommendation": None, "valid_value_ratio": 1.0}}
        for col, sem, priv in cols:
            res[col] = {"recommendation": {"semantic_category": sem, "privacy_category": priv,
                                           "confidence": rng.choice(["HIGH", "HIGH", "MEDIUM"])},
                        "valid_value_ratio": round(rng.uniform(0.85, 1.0), 3)}
        _classified(s, t, res)
    # a sample of non-PII tables classified with nothing sensitive in them
    for t in rng.sample([t for t in b.cat["tables"] if not t["pii"] and t["type"] == "BASE TABLE"], 25):
        res = {c: {"recommendation": None if c != "REGION" else {
                   "semantic_category": None, "privacy_category": "INSENSITIVE", "confidence": "HIGH"},
                   "valid_value_ratio": 1.0} for c in ("ID", "AMOUNT", "REGION", "UPDATED_AT")}
        _classified(s, t, res)
    return pii


def _classified(s: _S, t, res) -> None:
    """The latest result; about one in nine tables had a later attempt that failed, with its error."""
    k = s.rng.randint(2, 120)
    attempt, err = k, None
    if s.rng.random() < 0.11:
        attempt, err = s.rng.randint(1, min(k - 1, 7)), s.rng.choice(CLASSIFY_ERRORS)
    s.b.au("DATA_CLASSIFICATION_LATEST", table_id=t["id"], table_name=t["name"], schema_id=t["schema_id"],
           schema_name=t["schema"], database_id=t["db_id"], database_name=t["db"], result=res,
           status=s.rng.choice(["CLASSIFIED", "CLASSIFIED", "REVIEWED"]),
           trigger_type=s.rng.choice(["AUTO CLASSIFICATION", "MANUAL"]), last_classified_on=s.b.ts(k, 3),
           last_classification_attempt=s.b.ts(attempt, 3), error_message=err)


MASKS = [
    # id, name, body, age days
    (9900, "MASK_EMAIL_FULL",
     "CASE WHEN IS_ROLE_IN_SESSION('FINANCE_ADMIN') OR IS_ROLE_IN_SESSION('RISK_ADMIN') THEN VAL ELSE '***' END", 400),
    (9901, "MASK_PHONE_PARTIAL",
     "CASE WHEN CURRENT_ROLE() IN ('SALES_READ', 'MARKETING_READ', 'PLATFORM_READ') THEN VAL "
     "ELSE REGEXP_REPLACE(VAL, '[0-9]', '#') END", 380),
    (9902, "MASK_NAME_HASH", "CASE WHEN IS_ROLE_IN_SESSION('RISK_WRITE') THEN VAL ELSE SHA2(VAL) END", 360),
    (9903, "MASK_ADDRESS", "SHA2(VAL)", 300),
    (9904, "MASK_CARD_LAST4", "CASE WHEN CURRENT_ROLE() IN ('SYSADMIN', 'FINANCE_ADMIN') THEN VAL ELSE RIGHT(VAL, 4) END", 250),
    (9905, "MASK_DOB_YEAR", "CASE WHEN IS_ROLE_IN_SESSION('RISK_ADMIN') THEN VAL ELSE DATE_TRUNC('YEAR', VAL) END", 200),
    (9906, "MASK_PII_LOOKUP",
     "CASE WHEN EXISTS (SELECT 1 FROM GOV_DB.POLICIES.PII_ACCESS_MAP m WHERE m.ROLE_NAME = CURRENT_ROLE()) "
     "THEN VAL ELSE NULL END", 150),
    (9907, "MASK_SALARY_OLD", "CASE WHEN CURRENT_ROLE() IN ('FINANCE_ADMIN') THEN VAL ELSE 0 END", 500),
    (9908, "MASK_LEGACY_SSN", "CASE WHEN CURRENT_ROLE() IN ('PUBLIC', 'OPS_READ') THEN VAL ELSE '###' END", 700),
    (9909, "MASK_FREE_TEXT", "CASE WHEN IS_ROLE_IN_SESSION('PRODUCT_ADMIN') THEN VAL ELSE NULL END", 4),
    (9911, "MASK_NAME_BY_REGION",
     "CASE WHEN EXISTS (SELECT 1 FROM GOV_DB.POLICIES.REGION_MAP m WHERE m.ROLE_NAME = CURRENT_ROLE() "
     "AND m.REGION = REGION) THEN VAL ELSE '***' END", 90),
]
SIGNATURES = {9911: "(VAL VARCHAR, REGION VARCHAR)"}          # a conditional mask: the second column decides
RAPS = [
    (9950, "RAP_TEAM_REGION", "EXISTS (SELECT 1 FROM GOV_DB.POLICIES.REGION_MAP m WHERE m.ROLE_NAME = CURRENT_ROLE() "
     "AND m.REGION = REGION)", 420),
    (9951, "RAP_RISK_ENTITLEMENT", "IS_ROLE_IN_SESSION('RISK_ADMIN') OR IS_ROLE_IN_SESSION('RISK_WRITE')", 300),
    (9952, "RAP_ADMIN_BYPASS", "CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SALES_ADMIN') OR REGION = 'GLOBAL'", 260),
    (9953, "RAP_OLD_REGION", "CURRENT_ROLE() = 'MARKETING_ADMIN'", 600),
]
DIRECT = {"EMAIL": 9900, "PHONE": 9901, "NAME": 9902, "ADDRESS": 9903, "CARD_NUMBER": 9904, "BIRTH_DATE": 9905,
          "ANNUAL_INCOME": 9907, "SSN": 9908}
DOMAINS = {"BASE TABLE": "TABLE", "VIEW": "VIEW", "MATERIALIZED VIEW": "MATERIALIZED VIEW",
           "DYNAMIC TABLE": "DYNAMIC TABLE"}


def _policies(s: _S, pii: list[dict]) -> None:
    b = s.b
    names = {pid: n for pid, n, *_ in MASKS + RAPS}
    for pid, name, body, age in MASKS:
        b.au("MASKING_POLICIES", policy_id=pid, policy_name=name, policy_schema_id=GOV_SCHEMA_ID,
             policy_schema=GOV_SCHEMA, policy_catalog_id=GOV_DB_ID, policy_catalog=GOV_DB, policy_owner="SECURITYADMIN",
             owner_role_type="ROLE", policy_signature=SIGNATURES.get(pid, "(VAL VARCHAR)"),
             policy_return_type="VARCHAR", policy_body=body,
             created=b.ts(age, 10), last_altered=b.ts(min(age, s.rng.randint(1, 90)), 10))
    for pid, name, body, age in RAPS:
        b.au("ROW_ACCESS_POLICIES", policy_id=pid, policy_name=name, policy_schema=GOV_SCHEMA, policy_catalog=GOV_DB,
             policy_owner="SECURITYADMIN", owner_role_type="ROLE", policy_signature="(REGION VARCHAR)",
             policy_return_type="BOOLEAN", policy_body=body, created=b.ts(age, 10),
             last_altered=b.ts(min(age, s.rng.randint(1, 90)), 10))
    b.au("MASKING_POLICIES", policy_id=9910, policy_name="MASK_RETIRED", policy_schema_id=GOV_SCHEMA_ID,
         policy_schema=GOV_SCHEMA, policy_catalog_id=GOV_DB_ID, policy_catalog=GOV_DB, policy_owner="SECURITYADMIN",
         owner_role_type="ROLE", policy_signature="(VAL VARCHAR)", policy_return_type="VARCHAR",
         policy_body="'***'", created=b.ts(600, 10), last_altered=b.ts(80, 10), deleted=b.ts(40, 10))

    def ref(pid, kind, t, col=None, status="ACTIVE", args=None):
        b.au("POLICY_REFERENCES", policy_db=GOV_DB, policy_schema=GOV_SCHEMA, policy_id=pid, policy_name=names[pid],
             policy_kind=kind, ref_database_name=t["db"], ref_schema_name=t["schema"], ref_entity_name=t["name"],
             ref_entity_domain=DOMAINS.get(t["type"], "TABLE"), ref_column_name=col,
             ref_arg_column_names=args, policy_status=status)

    first_dob = True
    for t in pii:
        mode = TEAM_PROTECTION[t["team"]]
        for col, _sem, _priv in _pii_columns(t):
            pid = DIRECT.get(col)
            if pid is None:
                continue
            if mode == "direct" or (mode == "partial" and col in ("EMAIL", "PHONE", "CARD_NUMBER")):
                status = "ACTIVE"
                if col == "BIRTH_DATE" and t["team"] == "RISK" and first_dob:
                    status, first_dob = "MULTIPLE_MASKING_POLICY_ASSIGNED_TO_THE_COLUMN", False
                ref(pid, "MASKING_POLICY", t, col, status)
        if t["team"] in ("SALES", "FINANCE"):
            ref(9950, "ROW_ACCESS_POLICY", t, args="[REGION]")
        if t["team"] == "RISK":
            ref(9951, "ROW_ACCESS_POLICY", t, args="[REGION]")
    # sales' conditional name mask: works on one table, the REGION argument is missing or mistyped on others
    sales = [t for t in pii if t["team"] == "SALES"]
    for t, status in zip(sales, ("ACTIVE", "COLUMN_IS_MISSING_FOR_SECONDARY_ARG",
                                 "COLUMN_DATATYPE_MISMATCH_FOR_SECONDARY_ARG")):
        ref(9911, "MASKING_POLICY", t, "NAME", status, args="[REGION]")
        if status == "ACTIVE":
            s.cond_active.add(t["id"])
    # the lookup mask covers marketing's lead tables' email through a tag that nobody applied yet (attached, no hits)
    mk = [t for t in pii if t["team"] == "MARKETING"][:1]
    for t in mk:
        ref(9906, "MASKING_POLICY", t, "POSTAL_CODE")
    # RAP_ADMIN_BYPASS sits on a non-PII sales table
    other = next((t for t in s.b.cat["tables"] if t["team"] == "SALES" and not t["pii"] and t["type"] == "BASE TABLE"),
                 None)
    if other:
        ref(9952, "ROW_ACCESS_POLICY", other, args="[REGION]")
    # a row access policy on a dynamic table and on a materialized view
    ref(9950, "ROW_ACCESS_POLICY", dict(db="FINANCE_PROD_DB", schema="MARTS", name="DT_REVENUE_DAILY",
                                        type="DYNAMIC TABLE"), args="[REGION]")
    mv = next((t for t in s.b.cat["tables"] if t["type"] == "MATERIALIZED VIEW" and t["team"] in ("SALES", "FINANCE")),
              None)
    if mv:
        ref(9950, "ROW_ACCESS_POLICY", mv, args="[REGION]")


def _policy_hits(s: _S, t, cols: list[str]) -> list[dict]:
    """POLICIES_REFERENCED for a read of these columns: the masks on them and the table's row access policy."""
    mode = TEAM_PROTECTION[t["team"]]
    col_pols = []
    for c in cols:
        pid = None
        if mode == "direct" or (mode == "partial" and c in ("EMAIL", "PHONE", "CARD_NUMBER")):
            pid = DIRECT.get(c)
        elif mode in ("tag_column", "tag_table") and c in PII_COLS:
            pid = 9401                                        # the base account's tag-based mask
        elif c == "NAME" and t["id"] in s.cond_active:
            pid = 9911
        if pid:
            name = "ANALYTICS_DB.PUBLIC.MASK_PII_TAG" if pid == 9401 else f"{GOV_DB}.{GOV_SCHEMA}.{_mask_name(pid)}"
            col_pols.append({"columnName": c, "policies": [{"policyName": name, "policyId": pid,
                                                             "policyKind": "MASKING_POLICY"}]})
    rap = {"SALES": 9950, "FINANCE": 9950, "RISK": 9951}.get(t["team"])
    if not col_pols and not rap:
        return []
    o = {"objectDomain": "Table", "objectName": f"{t['db']}.{t['schema']}.{t['name']}", "objectId": t["id"],
         "columns": col_pols}
    if rap:
        o["policies"] = [{"policyName": f"{GOV_DB}.{GOV_SCHEMA}.{'RAP_TEAM_REGION' if rap == 9950 else 'RAP_RISK_ENTITLEMENT'}",
                          "policyId": rap, "policyKind": "ROW_ACCESS_POLICY"}]
    return [o]


def _mask_name(pid: int) -> str:
    return next(n for i, n, *_ in MASKS if i == pid)


# ---- queries that read PII, some under admin roles -----------------------------------------------------------------
def _query(s: _S, user, role, wh, t, start, qtype="SELECT", cols=None) -> None:
    b, w = s.b, s.w
    s.qn += 1
    qid = f"01dsec-{s.qn:07d}"
    whr = w.wh_by_name[wh]
    ms = s.rng.randint(400, 40_000)
    u = s.users.get(user) or {}
    b.au("QUERY_HISTORY", query_id=qid, query_text=f"{qtype.lower()} 1", database_id=t["db_id"],
         database_name=t["db"], schema_id=t["schema_id"], schema_name=t["schema"], query_type=qtype, session_id=None,
         user_name=user, role_name=role, warehouse_id=whr["id"], warehouse_name=wh, warehouse_size=w.size_at(whr, start),
         warehouse_type=whr["type"], cluster_number=1, execution_status="SUCCESS", start_time=start,
         end_time=start + dt.timedelta(milliseconds=ms), total_elapsed_time=ms + 150, compilation_time=150,
         execution_time=ms, queued_provisioning_time=0, queued_overload_time=0,
         bytes_scanned=int(ms * 2e4), partitions_scanned=20, partitions_total=200, query_tag=None,
         credits_used_cloud_services=0.0001, query_hash=f"hsec{t['id'] % 50}w{whr['id']}", query_parameterized_hash=f"hsec{t['id'] % 50}w{whr['id']}",
         role_type="ROLE", user_type="SERVICE" if u.get("type", "PERSON") != "PERSON" else "PERSON",
         secondary_role_stats='{"roles": "ALL"}' if u.get("new") and user in ("TEO_HOLM", "MILO_HOLM") else None)
    cols = cols or ["ID"]
    obj = {"objectDomain": "Table", "objectName": f"{t['db']}.{t['schema']}.{t['name']}", "objectId": t["id"],
           "columns": [{"columnId": _col_id(t["name"], c), "columnName": c} for c in cols]}
    modified = []
    if qtype != "SELECT":
        modified = [{"objectDomain": "Table", "objectName": obj["objectName"], "objectId": t["id"],
                     "columns": [{"columnId": _col_id(t["name"], "ID"), "columnName": "ID",
                                  "directSources": [], "baseSources": []}]}]
    b.au("ACCESS_HISTORY", query_id=qid, query_start_time=start, user_name=user,
         direct_objects_accessed=[obj] if qtype == "SELECT" else [], base_objects_accessed=[obj] if qtype == "SELECT" else [],
         objects_modified=modified, policies_referenced=_policy_hits(s, t, cols) if qtype == "SELECT" else [],
         root_query_id=qid)


def _active(u: dict, d: int) -> bool:
    """The user exists, is enabled and had signed in by day d (days back)."""
    last = u.get("last_login_days")
    return not u.get("disabled") and last is not None and last <= d < u["created_days"]


def _queries(s: _S, pii: list[dict]) -> None:
    b, rng = s.b, s.rng
    people = {}
    for n, u in s.users.items():
        if u["type"] == "PERSON" and not u.get("new") and not u.get("disabled") and u["last_login_days"] is not None \
                and u["last_login_days"] < 15:
            people.setdefault(u["team"], []).append(n)
    by_team: dict[str, list] = {}
    for t in pii:
        if t["type"] == "BASE TABLE":
            by_team.setdefault(t["team"], []).append(t)

    def cols_of(t):
        names = [c for c, *_ in _pii_columns(t)]
        return ["ID"] + rng.sample(names, rng.randint(1, min(3, len(names))))

    def days(user, lo, hi):
        return [d for d in range(lo, hi + 1) if _active(s.users[user], d)]

    # everyday analyst reads of PII, so the masks show up as evaluated
    for d in range(1, 96):
        for team, ts_ in by_team.items():
            if team not in people or team == "OPS":
                continue
            for _ in range(rng.choice([0, 1, 1, 2])):
                who = [n for n in people[team] if _active(s.users[n], d)]
                if not who:
                    continue
                user = rng.choice(who)
                role = s.users[user]["default_role"]
                t = rng.choice(ts_)
                _query(s, user, role, f"WH_{team}_BI", t, b.ts(d, rng.randint(8, 18), rng.randint(0, 59)), cols=cols_of(t))
    # admin roles doing data work: the new ACCOUNTADMIN browses marketing PII; a SYSADMIN runs the DS reads;
    # a service user writes under ACCOUNTADMIN; SECURITYADMIN does access admin (fine)
    mkt = by_team.get("MARKETING", []) or pii[:1]
    amir = days("AMIR_NOOR", 1, 6)
    for k in range(26 if amir else 0):
        t = rng.choice(mkt)
        _query(s, "AMIR_NOOR", ACCOUNTADMIN, "WH_PLATFORM_ADHOC", t, b.ts(rng.choice(amir), rng.randint(7, 20), k),
               cols=cols_of(t))
    dsc = by_team.get("DATA_SCIENCE", []) or pii[:1]
    chen = days("CHEN_TAMM", 1, 28)
    for k in range(30 if chen else 0):
        t = rng.choice(dsc)
        _query(s, "CHEN_TAMM", SYSADMIN, "WH_DATA_SCIENCE_ADHOC", t, b.ts(rng.choice(chen), rng.randint(8, 19), k),
               cols=cols_of(t))
    ops = [t for t in b.cat["tables"] if t["team"] == "OPS" and t["schema"] == "STAGING" and t["type"] == "BASE TABLE"]
    for k in range(8):
        if ops:
            _query(s, "SVC_OPS_INGEST", ACCOUNTADMIN, "WH_OPS_ETL", rng.choice(ops), b.ts(rng.randint(1, 28), 2, k),
                   qtype="INSERT")
    plat = [t for t in b.cat["tables"] if t["team"] == "PLATFORM" and t["type"] == "BASE TABLE"]
    for k in range(40):
        _query(s, "SVC_PLATFORM_INGEST", SYSADMIN, "WH_PLATFORM_ETL", rng.choice(plat), b.ts(rng.randint(1, 29), 3, k),
               qtype="MERGE")
    ike = days("IKE_BRANDT", 1, 29)
    for k in range(12 if ike else 0):
        t = rng.choice(plat)
        _query(s, "IKE_BRANDT", SECURITYADMIN, "WH_PLATFORM_ADHOC", t, b.ts(rng.choice(ike), 10, k),
               qtype=rng.choice(["GRANT", "REVOKE", "CREATE_USER", "ALTER_USER"]))
    teo = days("TEO_HOLM", 1, 20)
    for k in range(10 if teo else 0):
        t = rng.choice([t for t in pii if t["team"] in ("SALES", "FINANCE")] or pii)
        _query(s, "TEO_HOLM", rng.choice(["SALES_READ", "FINANCE_READ"]), "WH_PLATFORM_ADHOC", t,
               b.ts(rng.choice(teo), 14, k), cols=cols_of(t))


# ---- integrations, secrets, keys -----------------------------------------------------------------------------------
def _integrations(s: _S) -> None:
    b = s.b
    rows = [("EAI_PAYMENTS_API", "EXTERNAL_ACCESS", "EXTERNAL_ACCESS", True, 21, ["FINANCE_WRITE", "SVC_INGEST_ROLE"]),
            ("EAI_ML_MODELS", "EXTERNAL_ACCESS", "EXTERNAL_ACCESS", True, 400,
             ["DATA_SCIENCE_READ", "DATA_SCIENCE_WRITE", "SVC_ML_ROLE", "PRODUCT_WRITE", "MARKETING_WRITE", "RISK_WRITE"]),
            ("S3_INT_FINANCE", "EXTERNAL_STAGE", "STORAGE", True, 300, ["FINANCE_WRITE", "SVC_INGEST_ROLE"]),
            ("S3_INT_MARKETING", "EXTERNAL_STAGE", "STORAGE", True, 500, ["MARKETING_WRITE", "PUBLIC"]),
            ("GCS_INT_LEGACY", "EXTERNAL_STAGE", "STORAGE", False, 900, ["OPS_WRITE"]),
            ("API_INT_GATEWAY", "API", "API", True, 250, ["PLATFORM_WRITE"]),
            ("NOTIFY_EMAIL_OPS", "EMAIL", "NOTIFICATION", True, 200, ["OPS_ADMIN"]),
            ("OAUTH_PARTNER_APP", "OAUTH - CUSTOM", "SECURITY", True, 9, []),
            ("SSO_SECONDARY_IDP", "SAML2", "SECURITY", False, 120, [])]
    for name, typ, cat, enabled, age, roles in rows:
        row = dict(name=name, type=typ, category=cat, enabled="true" if enabled else "false", comment="",
                   created_on=b.ts(age, 11))
        b.show("integrations", **row)
        if cat == "SECURITY":
            b.show("security_integrations", **row)
        if name != "EAI_PAYMENTS_API":                       # its ownership moved in the window (see _role_grants)
            _gr(s, "OWNERSHIP", "INTEGRATION", name, ACCOUNTADMIN, age, by=ACCOUNTADMIN)
        for r in roles:
            _gr(s, "USAGE", "INTEGRATION", name, r, s.rng.randint(1, age), by=ACCOUNTADMIN)


def _secrets(s: _S) -> None:
    b = s.b
    sch = {(x["db"], x["name"]): x for x in b.cat["schemas"]}
    rows = [(9990, "SEC_SFTP_PASSWORD", "OPS_PROD_DB", "RAW", "PASSWORD", 420, "OPS_ADMIN", ["OPS_WRITE"]),
            (9991, "SEC_PAYMENTS_API_KEY", "FINANCE_PROD_DB", "RAW", "GENERIC_STRING", 30, "FINANCE_ADMIN",
             ["FINANCE_WRITE", "SVC_INGEST_ROLE"]),
            (9992, "SEC_ML_OAUTH", "DATA_SCIENCE_PROD_DB", "RAW", "OAUTH2", 220, "DATA_SCIENCE_ADMIN", ["SVC_ML_ROLE"]),
            (9993, "SEC_PARTNER_TOKEN", "MARKETING_PROD_DB", "RAW", "GENERIC_STRING", 60, "MARKETING_ADMIN",
             ["MARKETING_WRITE", "PUBLIC"]),
            (9994, "SEC_DB_LINK_PW", "PLATFORM_PROD_DB", "RAW", "PASSWORD", 90, SYSADMIN,
             ["PLATFORM_WRITE", "SVC_INGEST_ROLE", "DATA_SCIENCE_WRITE", "RISK_WRITE"])]
    for sid, name, db, schema, typ, age, owner, users in rows:
        x = sch[(db, schema)]
        b.au("SECRETS", id=sid, name=name, schema_id=x["id"], schema=schema, database_id=x["db_id"], database=db,
             owner=owner, owner_role_type="ROLE", secret_type=typ,
             oauth_scopes="session:role-any" if typ == "OAUTH2" else None, comment=None,
             created_on=b.ts(age + 30, 9), last_altered_on=b.ts(age, 9))
        _gr(s, "OWNERSHIP", "SECRET", name, owner, age + 30, catalog=db, schema=schema)
        for r in users:
            _gr(s, "USAGE", "SECRET", name, r, s.rng.randint(1, age), catalog=db, schema=schema)


def _keys(s: _S) -> None:
    """Key pairs for the service users that have one: some fresh, some old, one unused, one rotated; the PATs and
    the workload identity whose use matches the sign-ins."""
    b, rng = s.b, s.rng
    cid = 7500
    for n, u in s.users.items():
        if not u.get("has_rsa"):
            continue
        ages = [rng.choice([40, 120, 250, 400, 700])]
        if rng.random() < 0.3:
            ages.append(rng.randint(5, 60))                   # a second key during rotation
        for age in ages:
            cid += 1
            age = min(age, u["created_days"])
            used = None if rng.random() < 0.1 else rng.choice([0, 0, 1, 2, 30, 120])
            b.au("CREDENTIALS", credential_id=cid, name=f"KEY_{n}_{cid}", user_name=n, type="KEYPAIR", domain="KEYPAIR",
                 status="ACTIVE", additional_details={"KEY_TYPE": "RSA", "PUBLIC_KEY_FP": f"SHA256:demo{cid}"},
                 created_by=n, last_altered_by=n,
                 created_on=b.ts(age, 9), last_used_on=b.ts(min(used, age), 6) if used is not None else None,
                 last_altered=b.ts(age, 9))
    # PAT_1 lived a year and was replaced by a 30-day token 25 days ago; both still ACTIVE
    for cid, (k, created_days, life) in zip(PAT_IDS, ((1, 125, 365), (2, 25, 30))):
        created = b.ts(created_days, 9)
        details = {"ROLE_RESTRICTION": "PLATFORM_WRITE"}
        if k == 1:
            details["ROTATED_TO"] = "PAT_SVC_DBT_PROD_2"
        b.au("CREDENTIALS", credential_id=cid, name=f"PAT_SVC_DBT_PROD_{k}", user_name="SVC_DBT_PROD",
             type="PAT", domain="PROGRAMMATIC_ACCESS_TOKEN", status="ACTIVE", additional_details=details,
             created_by="PLATFORM_ADMIN", last_altered_by="PLATFORM_ADMIN", created_on=created,
             last_used_on=s.cred_used.get(cid), last_altered=created, expiration_date=created + dt.timedelta(days=life))
    b.au("CREDENTIALS", credential_id=WIF_ID, name="WIF_SVC_DEPLOY_WIF", user_name="SVC_DEPLOY_WIF", type="AWS",
         domain="WORKLOAD_IDENTITY_FEDERATION_METHOD", status="ENROLLED",
         additional_details={"aws_partition": "aws", "aws_account": "000000000000", "type": "IAM_ROLE",
                             "iam_role": "arn:aws:iam::000000000000:role/demo-deploy"},
         created_by="PLATFORM_ADMIN", last_altered_by="PLATFORM_ADMIN", created_on=b.ts(90, 11),
         last_used_on=s.cred_used.get(WIF_ID), last_altered=b.ts(90, 11))


# ---- Trust Center --------------------------------------------------------------------------------------------------
TC_SCANNERS = [
    # package id, package name, scanner id, name, type, severity, who is at risk, first run (days back)
    ("SECURITY_ESSENTIALS", "Security Essentials", "SE_MFA_PASSWORD_USERS", "Password users without MFA",
     "Vulnerability", "CRITICAL", "no_mfa", 90),
    ("SECURITY_ESSENTIALS", "Security Essentials", "SE_NETWORK_POLICY", "Users without a network policy",
     "Vulnerability", "HIGH", "no_np", 90),
    ("CIS_BENCHMARKS", "CIS Benchmarks", "CIS_1_6", "Service users that still have a password", "Vulnerability",
     "HIGH", "svc_pw", 90),
    ("CIS_BENCHMARKS", "CIS Benchmarks", "CIS_1_12", "Users with an admin default role", "Vulnerability",
     "MEDIUM", "admin_default", 90),
    ("CIS_BENCHMARKS", "CIS Benchmarks", "CIS_3_1", "Account-level network policy", "Vulnerability", "LOW",
     "nobody", 90),
    ("THREAT_INTELLIGENCE", "Threat Intelligence", "TI_DORMANT_USERS", "Dormant users with access",
     "Detection", "MEDIUM", "stale", 90),
    ("THREAT_INTELLIGENCE", "Threat Intelligence", "TI_AUTH_FAILURES", "Repeated failed sign-ins", "Detection",
     "HIGH", "failed", 90),
    ("AI_SECURITY", "AI Security", "AI_CORTEX_BROAD_ACCESS", "Cortex functions open to PUBLIC", "Vulnerability",
     "MEDIUM", "public", 32),
    ("AI_SECURITY", "AI Security", "AI_AGENT_ADMIN_OWNER", "Agents owned by admin roles", "Vulnerability",
     "HIGH", "agents", 32),
]


def _trust_center(s: _S) -> None:
    """A weekly scanner run per package over the window, plus the ACCOUNT_USAGE finding lifecycle."""
    b, rng = s.b, s.rng
    people = {n: u for n, u in s.users.items() if u["type"] == "PERSON"}
    pools = {
        "no_mfa": [n for n, u in people.items() if u.get("has_password") and not u.get("has_mfa")],
        "no_np": [n for n, u in s.users.items() if u["type"] != "PERSON"][-4:],
        "svc_pw": [n for n, u in s.users.items() if u["type"] != "PERSON" and u.get("has_password")],
        "admin_default": [n for n, u in s.users.items() if u["default_role"] in (ACCOUNTADMIN, SECURITYADMIN)],
        "nobody": [],
        "stale": [n for n, u in people.items() if u["last_login_days"] is None or u["last_login_days"] > 90],
        "failed": ["HANA_WEIR", "AMIR_NOOR", "WREN_DORN", "SVC_MARKETING_INGEST"],
        "public": ["PUBLIC"],
        "agents": ["DATA_SCIENCE_PROD_DB.MARTS.SUPPORT_AGENT"],
    }
    etype = {"public": "ROLE", "agents": "AGENT", "nobody": "ACCOUNT"}
    n = 0
    for k in range(87, 0, -7):                               # weekly, the base run sits on day 2
        for pkg, pkg_name, sid, name, stype, sev, pool, start in TC_SCANNERS:
            if k > start:
                continue
            n += 1
            failed = pkg == "THREAT_INTELLIGENCE" and k == 45
            ents = pools[pool]
            keep = max(0, round(len(ents) * (0.55 + 0.45 * k / 87))) if pool not in ("failed", "public") else len(ents)
            if pool == "agents" and k < 14:
                keep = 0                                     # moved to a functional role two weeks ago
            at_risk = [] if failed else [{"entity_name": e, "entity_type": etype.get(pool, "USER")} for e in ents[:keep]]
            when = b.ts(k, 3, rng.randint(0, 40))
            b.w.add("trust_center", "FINDINGS", dict(
                scanner_id=sid, scanner_name=name, scanner_short_description=name, scanner_type=stype,
                scanner_package_id=pkg, scanner_package_name=pkg_name, severity=sev,
                completion_status="FAILED" if failed else "SUCCEEDED", created_on=when,
                total_at_risk_count=None if failed else len(at_risk), at_risk_entities=at_risk,
                event_id=f"tc-demo-{n:04d}"))
    # the finding lifecycle in ACCOUNT_USAGE: package x severity, open, resolved and resolved by hand
    life = [("SECURITY_ESSENTIALS", "SE_MFA_PASSWORD_USERS", "CRITICAL", "OPEN", 10, 3),
            ("SECURITY_ESSENTIALS", "SE_NETWORK_POLICY", "HIGH", "RESOLVED", 80, 33),
            ("SECURITY_ESSENTIALS", "SE_NETWORK_POLICY", "HIGH", "RESOLVED", 40, 24),
            ("SECURITY_ESSENTIALS", "SE_MFA_PASSWORD_USERS", "LOW", "RESOLVED MANUALLY", 70, 50),
            ("CIS_BENCHMARKS", "CIS_1_12", "MEDIUM", "OPEN", 12, 5),
            ("CIS_BENCHMARKS", "CIS_3_1", "LOW", "RESOLVED MANUALLY", 60, 45),
            ("THREAT_INTELLIGENCE", "TI_DORMANT_USERS", "MEDIUM", "OPEN", 33, 3),
            ("THREAT_INTELLIGENCE", "TI_AUTH_FAILURES", "HIGH", "RESOLVED MANUALLY", 9, 6),
            ("THREAT_INTELLIGENCE", "TI_AUTH_FAILURES", "HIGH", "RESOLVED", 55, 52),
            ("AI_SECURITY", "AI_AGENT_ADMIN_OWNER", "HIGH", "RESOLVED", 32, 13),
            ("AI_SECURITY", "AI_CORTEX_BROAD_ACCESS", "MEDIUM", "OPEN", 25, 3),
            ("AI_SECURITY", "AI_CORTEX_BROAD_ACCESS", "LOW", "OPEN", 30, 3)]
    for pkg, scanner, sev, state, created, updated in life:
        b.au("TRUST_CENTER_FINDINGS", id=1, provider_id="SNOWFLAKE", scanner_package_id=pkg, scanner_id=scanner,
             severity=sev, state=state, created_on=b.ts(created, 3), updated_on=b.ts(updated, 3, 30))
