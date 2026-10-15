"""Fake views and rows for the second gap batch (network policies, Native App inventory, listing auto-fulfillment,
Query Insights per warehouse, unread churning tables, resource monitor projection).

Columns and types are the documented ones. `add(world)` runs after gap_security_data.add; each check gets OK and WARN
or CRITICAL rows. This module owns the SHOW APPLICATIONS table and the two listing auto-fulfillment DATA_SHARING_USAGE
views and the organization one. Existing fake rows also show up in these checks (NP_CORP, NP_UNUSED, DATA_APP_A..D,
WH_INS_*), so the expected statuses below list only what this module adds.
"""
from __future__ import annotations

import datetime as dt

GB = 1024 ** 3
TB = 1024 ** 4

AU: dict = {}
OU = {
    "LISTING_AUTO_FULFILLMENT_USAGE_HISTORY": "ORGANIZATION_NAME:s CONTRACT_NUMBER:s ACCOUNT_NAME:s ACCOUNT_LOCATOR:s "
        "REGION:s SERVICE_LEVEL:s USAGE_DATE:d SERVICE_TYPE:s CURRENCY:s ESTIMATED_USAGE:f ESTIMATED_USAGE_IN_CURRENCY:f "
        "PROVIDER_ACCOUNT_REGION:s PROVIDER_ACCOUNT_NAME:s PROVIDER_ACCOUNT_LOCATOR:s",
}
DSU = {
    "LISTING_AUTO_FULFILLMENT_REFRESH_DAILY": "REGION_GROUP:s SNOWFLAKE_REGION:s USAGE_DATE:d FULFILLMENT_GROUP_NAME:s "
        "BYTES_TRANSFERRED:n CREDITS_USED:f DATABASES:j LISTINGS:j",
    "LISTING_AUTO_FULFILLMENT_DATABASE_STORAGE_DAILY": "REGION_GROUP:s SNOWFLAKE_REGION:s USAGE_DATE:d DATABASE_NAME:s "
        "SOURCE_DATABASE_ID:n DELETED:t AVERAGE_DATABASE_BYTES:f AVERAGE_FAILSAFE_BYTES:f LISTINGS:j",
}
SHOW = {
    "applications": "created_on:t name:s is_default:s is_current:s source_type:s source:s owner:s comment:s version:s "
        "label:s patch:n options:s retention_time:n upgrade_state:s disablement_reasons:s last_upgraded_on:t "
        "release_channel_name:s type:s",
}
SHOW_PRE = {"SHOW APPLICATIONS": "applications"}


def add(w) -> None:
    """Rows for every new check: OK, WARN and CRITICAL where the check has the levels."""
    def t(back, h=9):
        return dt.datetime.combine(w.as_of - dt.timedelta(days=back), dt.time(h))

    def day(back):
        return w.as_of - dt.timedelta(days=back)

    au = w.au

    # 1. network policies: NP_NEW_UNUSED is unattached but 3 days old (OK); NP_INTEG is set on a security integration (OK).
    #    The older NP_UNUSED (WARN) and NP_CORP (OK) come from data.py.
    for pid, name, created in ((9510, "NP_NEW_UNUSED", 3), (9511, "NP_INTEG", 200)):
        au("NETWORK_POLICIES", dict(id=pid, name=name, owner="SECURITYADMIN", owner_role_type="ROLE", created=t(created),
                                    last_altered=t(created), allowed_ip_list="198.51.100.0/24", blocked_ip_list=""))
    au("POLICY_REFERENCES", dict(policy_db="SEC_DB", policy_schema="POLICIES", policy_id=9511, policy_name="NP_INTEG",
                                 policy_kind="NETWORK_POLICY", ref_entity_name="INT_SSO", ref_entity_domain="INTEGRATION",
                                 policy_status="ACTIVE"))

    # 2. Native App inventory. DATA_APP_A and _B are used (OK); DATA_APP_C is disabled (WARN); DATA_APP_D's upgrade failed
    #    (WARN); APP_IDLE is 100 days old with no usage (WARN); APP_NEW is 5 days old with no usage (OK); APP_POWER has
    #    usage rows but is not in SHOW (NOT_ASSESSED).
    apps = (("DATA_APP_A", 200, None, "COMPLETE"), ("DATA_APP_B", 180, None, "COMPLETE"),
            ("DATA_APP_C", 150, "DISABLED_BY_PROVIDER", "COMPLETE"), ("DATA_APP_D", 120, None, "FAILED"),
            ("APP_IDLE", 100, None, "COMPLETE"), ("APP_NEW", 5, None, "COMPLETE"))
    for name, age, disabled, upgrade in apps:
        w.show("applications", dict(created_on=t(age), name=name, is_default="N", is_current="N",
                                    source_type="LISTING", source="GZ_" + name, owner="APP_ADMIN", comment="",
                                    version="V1", label="v1", patch=2, options="", retention_time=1,
                                    upgrade_state=upgrade, disablement_reasons=disabled, last_upgraded_on=t(30),
                                    release_channel_name="DEFAULT", type="NATIVE"))

    # 3. listing auto-fulfillment (3 USD a credit). EU: FG_EU flat 2 a day (OK), FG_SMALL under the floor (OK), FG_NEW
    #    starts in the window (WARN), FG_NOLIST serves no listing (WARN). APAC: FG_APAC grows 1 -> 5 a day (CRITICAL).
    groups = (("AWS_EU_WEST_1", "FG_EU", 2.0, 2.0, ["LISTING_ONE"]),
              ("AWS_EU_WEST_1", "FG_SMALL", 0.05, 0.05, ["LISTING_ONE"]),
              ("AWS_EU_WEST_1", "FG_NEW", 1.0, 0.0, ["LISTING_TWO"]),
              ("AWS_EU_WEST_1", "FG_NOLIST", 1.0, 1.0, []),
              ("AZURE_WESTEUROPE", "FG_APAC", 5.0, 1.0, ["LISTING_ONE", "LISTING_TWO"]))
    for back in range(1, 61):
        cur = back <= 30
        for region, group, c_cur, c_prev, listings in groups:
            credits = c_cur if cur else c_prev
            if credits == 0:
                continue
            w.add("data_sharing_usage", "LISTING_AUTO_FULFILLMENT_REFRESH_DAILY", dict(
                region_group="PUBLIC", snowflake_region=region, usage_date=day(back), fulfillment_group_name=group,
                bytes_transferred=int(credits * 10 * GB), credits_used=credits, databases=["SALES_DB"], listings=listings))
        for region, database, size in (("AWS_EU_WEST_1", "SALES_DB", 400 * GB), ("AWS_EU_WEST_1", "REF_DB", 100 * GB),
                                       ("AZURE_WESTEUROPE", "SALES_DB", 400 * GB)):
            w.add("data_sharing_usage", "LISTING_AUTO_FULFILLMENT_DATABASE_STORAGE_DAILY", dict(
                region_group="PUBLIC", snowflake_region=region, usage_date=day(back), database_name=database,
                source_database_id=3, deleted=None, average_database_bytes=float(size),
                average_failsafe_bytes=float(size) * 0.1, listings=["LISTING_ONE"]))

    # 3b. the organization view (currency; window starts 3 settle days back): REPLICATION grows 100 -> 300 (WARN),
    #     DATA_TRANSFER costs 1500 (CRITICAL), STORAGE is 20 (OK)
    for back in range(4, 64):
        cur = back <= 33
        for service, c_cur, c_prev in (("REPLICATION", 10.0, 3.3), ("DATA_TRANSFER", 50.0, 50.0), ("STORAGE", 0.66, 0.66)):
            cost = c_cur if cur else c_prev
            w.add("organization_usage", "LISTING_AUTO_FULFILLMENT_USAGE_HISTORY", dict(
                organization_name="FAKE_ORG", contract_number="4001", account_name="SHARE_AREA", account_locator="SSA01",
                region="AWS_US_EAST_1", service_level="ENTERPRISE", usage_date=day(back), service_type=service,
                currency="USD", estimated_usage=cost / 3.0, estimated_usage_in_currency=cost,
                provider_account_region="AWS_US_EAST_1", provider_account_name="FAKE_ACCOUNT",
                provider_account_locator="FAKE01"))

    # 4. Query Insights per warehouse, each with 100 credits of metering in the window. WH_G2_A 6 flagged queries use
    #    1 credit (OK); _B uses 15 (WARN); _C uses 40 (CRITICAL); _D has only 2 flagged queries (OK); _E has flagged queries
    #    with no attribution (NOT_ASSESSED); _F has attribution but no metering (NOT_ASSESSED).
    for i, (letter, flagged, attributed, metered) in enumerate((("A", 6, 1.0, True), ("B", 6, 15.0, True),
                                                                ("C", 6, 40.0, True), ("D", 2, 1.0, True),
                                                                ("E", 6, None, True), ("F", 6, 1.0, False))):
        wid, name = 1401 + i, f"WH_G2_{letter}"
        if metered:
            for back in range(1, 31):
                au("WAREHOUSE_METERING_HISTORY", dict(start_time=t(back, 9), end_time=t(back, 10), warehouse_id=wid,
                                                      warehouse_name=name, credits_used=100 / 30,
                                                      credits_used_compute=100 / 30, credits_used_cloud_services=0.0))
                # The bill must carry the same credits, or the tag split no longer ties to it.
                day = t(back, 9).date()
                for r in w.rows[("account_usage", "METERING_DAILY_HISTORY")]:
                    if r["service_type"] == "WAREHOUSE_METERING" and r["usage_date"] == day:
                        for k in ("credits_used_compute", "credits_used", "credits_billed"):
                            r[k] += 100 / 30
                        break
        for k in range(flagged):
            qid = f"g2-{letter}-{k}"
            back = 3 + k
            for n, itype in enumerate(("QUERY_INSIGHT_SPILL", "QUERY_INSIGHT_NO_FILTER")[: 2 if k == 0 else 1]):
                au("QUERY_INSIGHTS", dict(start_time=t(back, 10), end_time=t(back, 11), total_elapsed_time=600000,
                                          query_id=qid, query_hash=f"hg2{letter}", query_parameterized_hash=f"hg2{letter}",
                                          warehouse_id=str(wid), warehouse_name=name, insight_instance_id=wid * 100 + k * 2 + n,
                                          insight_type_id=itype, message=["m"], suggestions=["s"], is_opportunity=True,
                                          insight_topic="performance"))
            if attributed is not None:
                au("QUERY_ATTRIBUTION_HISTORY", dict(
                    query_id=qid, warehouse_id=wid, warehouse_name=name, query_hash=f"hg2{letter}",
                    query_parameterized_hash=f"hg2{letter}", user_name="ANALYST_DAN", start_time=t(back, 10),
                    end_time=t(back, 11), credits_attributed_compute=attributed / flagged))

    # 5. tables that change often: GAP2_READ is read (OK); GAP2_LOW_CHURN changes few rows (OK); GAP2_UNREAD_SMALL is
    #    never read with small history (WARN); GAP2_UNREAD_BIG is never read and holds 10 TB of history (CRITICAL).
    db, sch = "ANALYTICS_DB", "CORE"
    tables = ((5901, "GAP2_READ", 100_000, 1 * GB, 1 * GB, True), (5902, "GAP2_LOW_CHURN", 1000, 1 * GB, 1 * GB, False),
              (5903, "GAP2_UNREAD_SMALL", 100_000, 1 * GB, 1 * GB, False),
              (5904, "GAP2_UNREAD_BIG", 100_000, 6 * TB, 4 * TB, False))
    sid, did = w.schema_id[(db, sch)], w.dbs[db]
    for tid, name, daily_rows, tt, fs, read in tables:
        au("TABLES", dict(table_id=tid, table_name=name, table_schema_id=sid, table_schema=sch, table_catalog_id=did,
                          table_catalog=db, table_owner="DATA_ENG", table_type="BASE TABLE", is_transient="NO",
                          row_count=10_000_000, bytes=int(100 * GB), retention_time=90, created=t(300),
                          last_altered=t(2), last_ddl=t(2), last_ddl_by="DATA_ENG", is_iceberg="NO", is_dynamic="NO",
                          is_hybrid="NO"))
        au("TABLE_STORAGE_METRICS", dict(id=tid, table_name=name, table_schema_id=sid, table_schema=sch,
                                         table_catalog_id=did, table_catalog=db, clone_group_id=tid, is_transient="NO",
                                         active_bytes=int(100 * GB), time_travel_bytes=int(tt), failsafe_bytes=int(fs),
                                         retained_for_clone_bytes=0, deleted=False, table_created=t(300)))
        for back in range(1, 31):
            au("TABLE_DML_HISTORY", dict(start_time=t(back, 3), end_time=t(back, 4), table_id=tid, table_name=name,
                                         schema_id=sid, schema_name=sch, database_id=did, database_name=db,
                                         rows_added=daily_rows if daily_rows > 1000 else 10, rows_removed=0,
                                         rows_updated=0))
        if read:
            for back in (2, 6, 10):
                au("ACCESS_HISTORY", dict(
                    query_id=f"g2read{back}", query_start_time=t(back, 11), user_name="ANALYST_DAN",
                    direct_objects_accessed=[{"objectName": f"{db}.{sch}.{name}", "objectId": tid, "objectDomain": "Table"}],
                    base_objects_accessed=[{"objectName": f"{db}.{sch}.{name}", "objectId": tid, "objectDomain": "Table"}]))

    # 6. resource monitors, monthly cycle started 10 days ago (quota 1000; rate = used / 10 a day). OK: 100 used (30 percent
    #    projected). WARN: PACE 500 used (150 percent, 10 days left), NOTIFY 700 used with no suspend step (210 percent, 4 days
    #    left). CRITICAL: SOON 950 used (0.5 days left, suspends), FULL 1000 used. NOT_ASSESSED: NOQUOTA, NEVER.
    def rm(name, quota, used, freq="MONTHLY", suspend=100):
        w.show("resource_monitors", dict(
            name=name, credit_quota=quota, used_credits=used, remaining_credits=None if quota is None else quota - used,
            level="WAREHOUSE", frequency=freq, start_time=t(10, 0), notify_at="80", suspend_at=suspend,
            suspend_immediately_at=None, created_on=t(300), owner="ACCOUNTADMIN", comment="", notify_users="ADMIN_ALICE"))

    rm("RM_G2_OK", 1000.0, 100.0)
    rm("RM_G2_PACE", 1000.0, 500.0)
    rm("RM_G2_NOTIFY", 1000.0, 700.0, suspend=None)
    rm("RM_G2_SOON", 1000.0, 950.0)
    rm("RM_G2_FULL", 1000.0, 1000.0)
    rm("RM_G2_NOQUOTA", None, 0.0)
    rm("RM_G2_NEVER", 500.0, 100.0, freq="NEVER")
