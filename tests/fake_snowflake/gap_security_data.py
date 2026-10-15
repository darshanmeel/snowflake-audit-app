"""Fake views and rows for the security gap checks (failover, private link, Trust Center age, data movement, org posture).

Columns and types are the documented ones. `add(world)` runs last in World.build; each check gets OK and WARN or CRITICAL rows.
"""
from __future__ import annotations

import datetime as dt

_USER_COLS = (
    "USER_ID:n NAME:s LOGIN_NAME:s EMAIL:s TYPE:s DISABLED:j SNOWFLAKE_LOCK:j HAS_PASSWORD:b MUST_CHANGE_PASSWORD:b "
    "HAS_MFA:b EXT_AUTHN_DUO:b HAS_RSA_PUBLIC_KEY:b HAS_PAT:b HAS_WORKLOAD_IDENTITY:b BYPASS_MFA_UNTIL:t "
    "LOCKED_UNTIL_TIME:t EXPIRES_AT:t LAST_SUCCESS_LOGIN:t PASSWORD_LAST_SET_TIME:t CREATED_ON:t DELETED_ON:t OWNER:s "
    "DEFAULT_ROLE:s DEFAULT_SECONDARY_ROLE:s DEFAULT_WAREHOUSE:s DEFAULT_NAMESPACE:s IS_FROM_ORGANIZATION_USER:b"
)
_POLICY_COLS = (
    "POLICY_NAME:s POLICY_ID:n POLICY_SCHEMA_ID:n POLICY_SCHEMA:s POLICY_CATALOG_ID:n POLICY_CATALOG:s "
    "POLICY_OWNER:s POLICY_SIGNATURE:s POLICY_RETURN_TYPE:s POLICY_BODY:s POLICY_COMMENT:j CREATED:t "
    "LAST_ALTERED:t DELETED:t OWNER_ROLE_TYPE:s"
)

AU = {
    "REPLICATION_GROUPS": "CREATED:t DELETED:t NAME:s TYPE:s COMMENT:s OBJECT_TYPES:s ALLOWED_INTEGRATION_TYPES:s "
        "REPLICATION_SCHEDULE:s OWNER:s IS_LISTING_AUTO_FULFILLMENT_GROUP:b ERROR_INTEGRATION:s "
        "IS_OPTIMIZED_REFRESH_ENABLED:b",
    "INGRESS_NETWORK_ACCESS_HISTORY": "EVENT_TIMESTAMP:t REQUEST_ID:s REQUEST_METHOD:s REQUEST_PATH:s USER_NAME:s "
        "CLIENT_IP:s CLIENT_PRIVATE_LINK_ID:s BYTES_RX:n BYTES_TX:n IS_SUCCESS:b ERROR_CODE:s ERROR_MESSAGE:s "
        "JOB_UUID:s REQUEST_AUTHORITY:s",
    "TRUST_CENTER_FINDINGS": "ID:n PROVIDER_ID:s SCANNER_PACKAGE_ID:s SCANNER_ID:s SEVERITY:s STATE:s CREATED_ON:t "
        "UPDATED_ON:t",
    "DATA_MOVEMENT_VIOLATIONS": "QUERY_ID:s ENFORCED_POLICY:s MOVEMENT_TYPE:s ALERTED_POLICIES:s USER_NAME:s "
        "DATA_ENTITIES:j TIMESTAMP:t",
    "DATA_MOVEMENT_POLICIES": "ID:n NAME:s SCHEMA_ID:n SCHEMA:s DATABASE_ID:n DATABASE:s OWNER:s COMMENT:s CREATED:t "
        "LAST_ALTERED:t DELETED:t OWNER_ROLE_TYPE:s",
    "OUTBOUND_PRIVATELINK_ENDPOINTS": "PROVIDER_RESOURCE_ID:s HOSTNAME:s SUBRESOURCE:s SNOWFLAKE_RESOURCE_ID:s "
        "ENDPOINT_STATE:s CREATED_ON:t LAST_ALTERED_ON:t DELETED_ON:t",
    "AGGREGATION_POLICIES": _POLICY_COLS,
    "PROJECTION_POLICIES": _POLICY_COLS,
}
OU = {
    "USERS": "ORGANIZATION_NAME:s ACCOUNT_LOCATOR:s ACCOUNT_NAME:s " + _USER_COLS,
    "TRUST_CENTER_FINDINGS": "ORGANIZATION_NAME:s ACCOUNT_LOCATOR:s ACCOUNT_NAME:s ID:n PROVIDER_ID:s "
        "SCANNER_PACKAGE_ID:s SCANNER_ID:s SEVERITY:s STATE:s CREATED_ON:t UPDATED_ON:t",
}
SHOW: dict = {}
SHOW_PRE: dict = {}

_LOC = "FAKE01"
_ORG = "FAKE_ORG"


def add(w) -> None:
    """Rows for every new check: OK, WARN and CRITICAL where the check has the levels."""
    def t(back, h=9):
        return dt.datetime.combine(w.as_of - dt.timedelta(days=back), dt.time(h))

    au = w.au

    # 1. failover readiness. RG_MAIN (its SHOW row comes from data.py) lacks users, roles, network policies and an error
    #    integration (WARN); RG_OK is complete (OK); RG_NOTARGET has no allowed account (WARN); RG_REPL is a
    #    replication group holding roles (OK, note); RG_HIDDEN is missing from SHOW (NOT_ASSESSED); RG_GONE deleted.
    full = "ACCOUNT PARAMETERS, DATABASES, ROLES, USERS, NETWORK POLICIES"
    groups = [("RG_MAIN", "FAILOVER", "DATABASES", "USING CRON 0 6 * * 1 UTC", None, None),
              ("RG_OK", "FAILOVER", full, "10 MINUTE", "NOTIFY_INT", None),
              ("RG_NOTARGET", "FAILOVER", full, "10 MINUTE", "NOTIFY_INT", None),
              ("RG_REPL", "REPLICATION", "DATABASES, ROLES", "60 MINUTE", "NOTIFY_INT", None),
              ("RG_HIDDEN", "FAILOVER", full, "10 MINUTE", "NOTIFY_INT", None),
              ("RG_GONE", "FAILOVER", "DATABASES", None, None, t(20))]
    for name, typ, objs, sched, err, deleted in groups:
        au("REPLICATION_GROUPS", dict(created=t(300), deleted=deleted, name=name, type=typ, comment="", object_types=objs,
                                      allowed_integration_types="SECURITY INTEGRATIONS" if "USERS" in objs else None,
                                      replication_schedule=sched, owner="ACCOUNTADMIN",
                                      is_listing_auto_fulfillment_group=False, error_integration=err,
                                      is_optimized_refresh_enabled=False))
    for name, typ, objs, sched, allowed in (("RG_OK", "FAILOVER", full, "10 MINUTE", f"{_ORG}.FAKE_ACCOUNT,{_ORG}.FAKE_DR"),
                                            ("RG_NOTARGET", "FAILOVER", full, "10 MINUTE", f"{_ORG}.FAKE_ACCOUNT"),
                                            ("RG_REPL", "REPLICATION", "DATABASES, ROLES", "60 MINUTE", f"{_ORG}.FAKE_ACCOUNT,{_ORG}.FAKE_DR")):
        w.show("replication_groups", dict(
            snowflake_region="AWS_US_EAST_1", created_on=t(300), account_name="FAKE_ACCOUNT", name=name, type=typ,
            comment="", is_primary="true", primary=f"{_ORG}.FAKE_ACCOUNT", object_types=objs, allowed_accounts=allowed,
            organization_name=_ORG, account_locator=_LOC, replication_schedule=sched, secondary_state=None,
            next_scheduled_refresh=t(-1, 6), owner="ACCOUNTADMIN"))

    # 2. private link: 90% of requests are private, so the account uses it. ADMIN_BOB (admin) has public
    #    requests (CRITICAL), ANALYST_DAN has public requests (WARN), ADMIN_ALICE and SVC_BI are private only (OK),
    #    a nameless caller only fails.
    n = 0

    def ingress(user, back, private, ok=True, ip="203.0.113.7"):
        nonlocal n
        n += 1
        au("INGRESS_NETWORK_ACCESS_HISTORY", dict(
            event_timestamp=t(back, 10), request_id=f"ing{n}", request_method="POST", request_path="/queries",
            user_name=user, client_ip=ip, client_private_link_id="vpce-0abc" if private else None, bytes_rx=100,
            bytes_tx=200, is_success=ok, error_code=None if ok else "390100", error_message=None,
            job_uuid=f"job{n}", request_authority="fake.example.com"))
    for k in range(1, 21):
        ingress("ADMIN_ALICE", k, True, ip="10.0.0.5")
        ingress("SVC_BI", k, True, ip="10.0.0.6")
        ingress("ANALYST_CARA", k, True, ip="10.0.0.7")
    for k in (2, 5):
        ingress("ADMIN_BOB", k, False, ip="198.51.100.9")
        ingress("ANALYST_DAN", k, False, ip="198.51.100.10")
    ingress(None, 3, False, ok=False, ip="198.51.100.11")

    # 3. Trust Center age (as of the export): CIS CRITICAL open 20 days (CRITICAL), MEDIUM open 40 days (WARN),
    #    LOW open 100 days (OK), a HIGH resolved in the window, and a recent open HIGH in a second package (OK)
    tc = [("CIS_BENCHMARKS", "CIS_1_1", "CRITICAL", "OPEN", 20, 20), ("CIS_BENCHMARKS", "CIS_1_2", "MEDIUM", "OPEN", 40, 40),
          ("CIS_BENCHMARKS", "CIS_1_3", "LOW", "OPEN", 100, 100), ("CIS_BENCHMARKS", "CIS_1_4", "HIGH", "RESOLVED", 30, 12),
          ("CIS_BENCHMARKS", "CIS_1_5", "HIGH", "RESOLVED MANUALLY", 20, 8),
          ("THREAT_INTELLIGENCE", "TI_1", "HIGH", "OPEN", 3, 3)]
    for i, (pkg, scanner, sev, state, created, updated) in enumerate(tc):
        au("TRUST_CENTER_FINDINGS", dict(id=1, provider_id="SNOWFLAKE", scanner_package_id=pkg, scanner_id=scanner,
                                         severity=sev, state=state, created_on=t(created), updated_on=t(updated)))

    # 4. data movement: one live policy plus a deleted one. ANALYST_DAN: alert-only copies to an external stage
    #    (WARN); ANALYST_CARA: 6 blocked attempts (WARN); ANALYST_EVA: one blocked download (OK)
    for pid, name, deleted in ((9701, "DM_POLICY", None), (9702, "DM_OLD", t(50))):
        au("DATA_MOVEMENT_POLICIES", dict(id=pid, name=name, schema_id=7, schema="POLICIES", database_id=3,
                                          database="GOV_DB", owner="SECURITYADMIN", created=t(200), last_altered=t(60),
                                          deleted=deleted, owner_role_type="ROLE"))
    q = 0

    def violation(user, mtype, back, enforced=None, alerted=None, tables=("ANALYTICS_DB.CORE.CUSTOMERS",)):
        nonlocal q
        q += 1
        au("DATA_MOVEMENT_VIOLATIONS", dict(query_id=f"dmq{q}", enforced_policy=enforced, movement_type=mtype,
                                            alerted_policies=alerted, user_name=user, data_entities=list(tables),
                                            timestamp=t(back, 14)))
    for k in (1, 4):
        violation("ANALYST_DAN", "COPY_INTO_EXTERNAL_STAGE", k, alerted="GOV_DB.POLICIES.DM_POLICY.RULE_A")
    for k in range(1, 7):
        violation("ANALYST_CARA", "SNOWSIGHT_UI", k, enforced="GOV_DB.POLICIES.DM_POLICY.RULE_B",
                  tables=("ANALYTICS_DB.CORE.CUSTOMERS", "ANALYTICS_DB.CORE.ORDERS"))
    violation("ANALYST_EVA", "SNOWSIGHT_UI", 2, enforced="GOV_DB.POLICIES.DM_POLICY.RULE_B")

    # 5. org posture. FAKE01 has a person without MFA and a service user on a password (WARN); FAKE02 has an open
    #    CRITICAL finding and mostly password-only people (CRITICAL); FAKE03 is clean (OK)
    def ou_user(loc, acct, uid, name, typ, pw, mfa, last=1):
        w.ou("USERS", dict(organization_name=_ORG, account_locator=loc, account_name=acct, user_id=uid, name=name,
                           login_name=name, email=None, type=typ, disabled=False, snowflake_lock=False, has_password=pw,
                           has_mfa=mfa, ext_authn_duo=False, has_rsa_public_key=False, has_pat=False,
                           last_success_login=t(last) if last is not None else None, created_on=t(500),
                           default_role="PUBLIC"))
    for i, (typ, pw, mfa) in enumerate([("PERSON", True, True), ("PERSON", True, False), ("SERVICE", True, False)]):
        ou_user("FAKE01", "FAKE_ACCOUNT", 100 + i, f"OU_P{i}", typ, pw, mfa)
    for i, (typ, pw, mfa) in enumerate([("PERSON", True, False), ("PERSON", True, False), ("PERSON", True, True)]):
        ou_user("FAKE02", "FAKE_DEV", 200 + i, f"OU_D{i}", typ, pw, mfa)
    for i, (typ, pw, mfa) in enumerate([("PERSON", False, False), ("SERVICE", False, False)]):
        ou_user("FAKE03", "FAKE_DORMANT", 300 + i, f"OU_Q{i}", typ, pw, mfa)
    ou_user("FAKE03", "FAKE_DORMANT", 399, "SNOWFLAKE", "SNOWFLAKE_SERVICE", True, False)
    for loc, acct, sev, state in (("FAKE01", "FAKE_ACCOUNT", "HIGH", "OPEN"), ("FAKE02", "FAKE_DEV", "CRITICAL", "OPEN"),
                                  ("FAKE03", "FAKE_DORMANT", "CRITICAL", "RESOLVED")):
        w.ou("TRUST_CENTER_FINDINGS", dict(organization_name=_ORG, account_locator=loc, account_name=acct, id=1,
                                           provider_id="SNOWFLAKE", scanner_package_id="CIS_BENCHMARKS",
                                           scanner_id="CIS_X", severity=sev, state=state, created_on=t(30),
                                           updated_on=t(5)))

    # 6. outbound endpoints: EP_OK used (OK); EP_FAILED (WARN); EP_STUCK pending 3 days (WARN); EP_IDLE created 100
    #    days ago with no rule and no call (NOT_ASSESSED, usage_not_visible); EP_GONE deleted. Host names are fake.
    hosts = {"EP_OK": "ep-ok.vpce.us-east-1.amazonaws.com", "EP_FAILED": "ep-failed.vpce.us-east-1.amazonaws.com",
             "EP_STUCK": "ep-stuck.privatelink.blob.core.windows.net", "EP_IDLE": "ep-idle.vpce.us-east-1.amazonaws.com",
             "EP_GONE": "ep-gone.vpce.us-east-1.amazonaws.com"}
    eps = [("EP_OK", "CREATED", 100, 100, None), ("EP_FAILED", "FAILED", 10, 10, None),
           ("EP_STUCK", "PENDING_CREATION", 3, 3, None), ("EP_IDLE", "CREATED", 100, 100, None),
           ("EP_GONE", "DELETING", 200, 20, t(20))]
    for name, state, created, altered, deleted in eps:
        au("OUTBOUND_PRIVATELINK_ENDPOINTS", dict(provider_resource_id=f"res-{name}", hostname=hosts[name],
                                                  subresource="blob" if "windows.net" in hosts[name] else None, snowflake_resource_id=name, endpoint_state=state,
                                                  created_on=t(created), last_altered_on=t(altered), deleted_on=deleted))
    au("NETWORK_RULES", dict(id=9701, name="RULE_PL_OK", schema_id=205, schema="NETWORK", database_id=102,
                             database="GOV_DB", owner="SECURITYADMIN", owner_role_type="ROLE", created=t(100),
                             last_altered=t(100), mode="EGRESS", type="PRIVATE_HOST_PORT",
                             value_list=f'["{hosts["EP_OK"]}:443"]'))
    au("EXTERNAL_ACCESS_HISTORY", dict(query_id="01pl-ok", hostnames=hosts["EP_OK"], status="Success", ip="10.9.9.9",
                                       source_cloud="AWS", source_region="us-east-1", target_cloud="AWS",
                                       target_region="us-east-1"))

    # 7. aggregation and projection policies: AGG_OK attached (OK); AGG_IDLE attached nowhere and old (WARN);
    #    PROJ_BROKEN attached with a data type mismatch (CRITICAL); PROJ_NEW unattached but 3 days old (OK)
    pols = [("AGG_OK", 9801, 200, None, True), ("AGG_IDLE", 9802, 200, None, False),
            ("PROJ_BROKEN", 9803, 200, None, True), ("PROJ_NEW", 9804, 3, None, False),
            ("PROJ_GONE", 9805, 200, t(30), False)]
    for name, pid, age, deleted, _ in pols:
        au("AGGREGATION_POLICIES" if name.startswith("AGG") else "PROJECTION_POLICIES",
           dict(policy_name=name, policy_id=pid, policy_schema_id=7, policy_schema="POLICIES", policy_catalog_id=3,
                policy_catalog="GOV_DB", policy_owner="SECURITYADMIN", created=t(age), last_altered=t(age),
                deleted=deleted, owner_role_type="ROLE"))
    for name, pid, _, _, attached in pols:
        if not attached:
            continue
        au("POLICY_REFERENCES", dict(
            policy_db="GOV_DB", policy_schema="POLICIES", policy_id=pid, policy_name=name,
            policy_kind="AGGREGATION_POLICY" if name.startswith("AGG") else "PROJECTION_POLICY",
            ref_database_name="ANALYTICS_DB", ref_schema_name="CORE", ref_entity_name="ORDERS", ref_entity_domain="TABLE",
            ref_column_name=None if name.startswith("AGG") else "AMOUNT",
            policy_status="ACTIVE" if name == "AGG_OK" else "COLUMN_DATATYPE_MISMATCH_FOR_SECONDARY_ARG"))
