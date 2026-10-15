"""Fake views and rows for the third batch of checks (adaptive attribution, anomalies, compute pools, tags, backups, shares).

Columns and types are the documented ones. `add(world)` runs last in World.build; each check gets OK and WARN or CRITICAL rows.
"""
from __future__ import annotations

import datetime as dt

AU = {
    "QUERY_METERING_HISTORY": "QUERY_ID:s WAREHOUSE_ID:n WAREHOUSE_NAME:s QUERY_METERING_HOUR:t QUERY_START_TIME:t "
        "QUERY_END_TIME:t PARENT_QUERY_ID:s ROOT_QUERY_ID:s USER_ID:n USER_NAME:s ROLE_NAME:s QUERY_HASH:s "
        "QUERY_PARAMETERIZED_HASH:s QUERY_TAG:s CREDITS_USED_COMPUTE:f CREDITS_USED_CLOUD_SERVICES:f CREDITS_USED:f",
    "ANOMALIES_DAILY": "DATE:d ANOMALY_ID:s IS_ANOMALY:b ACTUAL_VALUE:f UPPER_BOUND:f LOWER_BOUND:f FORECASTED_VALUE:f",
    "COMPUTE_POOLS": "NAME:s ID:n IS_SUSPENDED:b MIN_NODES:n MAX_NODES:n INSTANCE_FAMILY:s AUTO_SUSPEND_SECS:n "
        "AUTO_RESUME:b CREATED:t LAST_RESUMED:t LAST_ALTERED:t DELETED:t OWNER:s OWNER_ROLE_TYPE:s IS_EXCLUSIVE:b "
        "APPLICATION_NAME:s APPLICATION_ID:n COMMENT:s",
    "TAGS": "TAG_ID:n TAG_NAME:s TAG_SCHEMA_ID:n TAG_SCHEMA:s TAG_DATABASE_ID:n TAG_DATABASE:s TAG_OWNER:s "
        "TAG_COMMENT:j CREATED:t LAST_ALTERED:t DELETED:t ALLOWED_VALUES:j OWNER_ROLE_TYPE:s PROPAGATE:s ON_CONFLICT:s",
    # The docs summary names only these columns; the check reads TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, DELETED.
    "COLUMNS": "TABLE_CATALOG:s TABLE_SCHEMA:s TABLE_NAME:s COLUMN_NAME:s DATA_TYPE:s DATA_TYPE_ALIAS:s "
        "ORDINAL_POSITION:n IS_NULLABLE:s COLUMN_DEFAULT:s KIND:s EXPRESSION:s DELETED:t",
    "BACKUP_STORAGE_USAGE": "BACKUP_SET_ID:n BACKUP_ID:s LOGICAL_BYTES:n INCREMENTAL_BYTES_FROM_PREVIOUS_BACKUP:n "
        "DECREMENTAL_BYTES_FROM_PREVIOUS_BACKUP:n",
    "SNAPSHOT_STORAGE_USAGE": "SNAPSHOT_SET_ID:n SNAPSHOT_ID:s LOGICAL_BYTES:n INCREMENTAL_BYTES_FROM_PREVIOUS_SNAPSHOT:n "
        "DECREMENTAL_BYTES_FROM_PREVIOUS_SNAPSHOT:n",
    "BACKUP_SETS": "ID:n NAME:s SCHEMA_ID:n SCHEMA_NAME:s CATALOG_ID:n CATALOG_NAME:s OBJECT_KIND:s OBJECT_ID:n "
        "OBJECT_NAME:s OBJECT_SCHEMA_ID:n OBJECT_SCHEMA_NAME:s OBJECT_CATALOG_ID:n OBJECT_CATALOG_NAME:s "
        "BACKUP_POLICY_ID:n BACKUP_POLICY_NAME:s BACKUP_POLICY_SCHEMA_ID:n BACKUP_POLICY_SCHEMA_NAME:s "
        "BACKUP_POLICY_CATALOG_ID:n BACKUP_POLICY_CATALOG_NAME:s OWNER:s OWNER_ROLE_TYPE:s CREATED:t LAST_ALTERED:t "
        "DELETED:t COMMENT:s",
    "SNAPSHOT_SETS": "ID:n NAME:s SCHEMA_ID:n SCHEMA_NAME:s CATALOG_ID:n CATALOG_NAME:s OBJECT_KIND:s OBJECT_ID:n "
        "OBJECT_NAME:s OBJECT_SCHEMA_ID:n OBJECT_SCHEMA_NAME:s OBJECT_CATALOG_ID:n OBJECT_CATALOG_NAME:s "
        "SNAPSHOT_POLICY_ID:n SNAPSHOT_POLICY_NAME:s SNAPSHOT_POLICY_SCHEMA_ID:n SNAPSHOT_POLICY_SCHEMA_NAME:s "
        "SNAPSHOT_POLICY_CATALOG_ID:n SNAPSHOT_POLICY_CATALOG_NAME:s OWNER:s OWNER_ROLE_TYPE:s CREATED:t "
        "LAST_ALTERED:t DELETED:t COMMENT:s",
    "GRANTS_TO_SHARES": "CREATED_ON:t MODIFIED_ON:t DELETED_ON:t PRIVILEGE:s GRANTED_ON:s OBJECT_NAME:s "
        "OBJECT_DATABASE:s OBJECT_SCHEMA:s SHARE_NAME:s GRANTED_BY:s GRANTED_BY_ROLE_TYPE:s",
    "DATA_METRIC_FUNCTION_EXPECTATIONS": "METRIC_DATABASE_NAME:s METRIC_SCHEMA_NAME:s METRIC_NAME:s ARGUMENT_SIGNATURE:s "
        "DATA_TYPE:s REF_DATABASE_NAME:s REF_SCHEMA_NAME:s REF_ENTITY_NAME:s REF_ENTITY_DOMAIN:s REF_ARGUMENTS:j "
        "REF_ID:s EXPECTATION_ID:s EXPECTATION_NAME:s",
    "DATA_METRIC_FUNCTION_REFERENCES": "METRIC_DATABASE_NAME:s METRIC_SCHEMA_NAME:s METRIC_NAME:s ARGUMENT_SIGNATURE:s "
        "DATA_TYPE:s REF_DATABASE_NAME:s REF_SCHEMA_NAME:s REF_ENTITY_NAME:s REF_ENTITY_DOMAIN:s REF_ARGUMENTS:j "
        "REF_ID:s SCHEDULE:s SCHEDULE_STATUS:s DATA_QUALITY_NOTIFICATION_STATUS:s ANOMALY_DETECTION_STATUS:s "
        "ANOMALY_DETECTION_SENSITIVITY_LEVEL:s USE_ROLE:s LEVEL:s EXCLUDE_TABLE_TYPES:s PROPERTIES:j",
}
DSU = {
    "MARKETPLACE_PAID_USAGE_DAILY": "REPORT_DATE:t USAGE_DATE:t PROVIDER_NAME:s PROVIDER_ACCOUNT_NAME:s "
        "PROVIDER_ACCOUNT_LOCATOR:s PROVIDER_ORGANIZATION_NAME:s LISTING_DISPLAY_NAME:s LISTING_GLOBAL_NAME:s "
        "DATABASE_NAME:s PO_NUMBER:s PRICING_PLAN:j CHARGE_TYPE:s UNITS:s UNIT_PRICE:f CHARGE:f CURRENCY:s",
}
SHOW = {
    "password_policies": "created_on:t name:s database_name:s schema_name:s kind:s owner:s comment:s "
        "owner_role_type:s options:s set_on:s",
}
SHOW_PRE = {"SHOW PASSWORD POLICIES": "password_policies"}


def add(w) -> None:
    """Rows for every new check: OK, WARN and CRITICAL where the check has the levels."""
    def t(back, h=9):
        return dt.datetime.combine(w.as_of - dt.timedelta(days=back), dt.time(h))

    def d(back):
        return w.as_of - dt.timedelta(days=back)

    au = w.au

    # 1. password policies (SHOW lists two account rows as a test double: WARN and CRITICAL; PW_STRICT is unattached)
    for i, (name, ml, age, retries) in enumerate([("PW_ACCT", 12, 90, 5), ("PW_OLD", 6, 0, 10), ("PW_STRICT", 16, 90, 5)]):
        au("PASSWORD_POLICIES", dict(id=8100 + i, name=name, schema_id=7, schema="POLICIES", database_id=3, database="GOV_DB",
                                     owner="SECURITYADMIN", owner_role_type="ROLE",
                                     password_min_length=ml, password_max_length=256, password_min_upper_case_chars=1,
                                     password_min_lower_case_chars=1, password_min_numeric_chars=1,
                                     password_min_special_chars=0, password_min_age_days=0, password_max_age_days=age,
                                     password_max_retries=retries, password_lockout_time_mins=15, password_history=0,
                                     created=t(300), last_altered=t(30)))
    for name in ("PW_ACCT", "PW_OLD"):
        w.show("password_policies", dict(created_on=t(300), name=name, database_name="GOV_DB", schema_name="POLICIES",
                                         kind="PASSWORD_POLICY", owner="SECURITYADMIN", comment="", owner_role_type="ROLE",
                                         options="{}", set_on="ACCOUNT"))

    # 2. adaptive warehouses: WH_ADAPTIVE (existing) attributed at 60% -> WARN; WH_ADAPTIVE_B at 95% -> OK
    wmh = [r for r in w.rows[("account_usage", "WAREHOUSE_METERING_HISTORY")] if r["warehouse_id"] == 1005]
    per_day = {}
    for r in wmh:
        per_day[r["start_time"].date()] = per_day.get(r["start_time"].date(), 0) + r["credits_used_compute"]
    n = 0
    for day, comp in per_day.items():
        if not (w.as_of - dt.timedelta(days=35) <= day < w.as_of):
            continue
        for user, share in (("ANALYST_DAN", 0.3), ("SVC_BI", 0.2), ("ANALYST_CARA", 0.1)):
            n += 1
            h = dt.datetime.combine(day, dt.time(10))
            au("QUERY_METERING_HISTORY", dict(query_id=f"qm{n}", warehouse_id=1005, warehouse_name="WH_ADAPTIVE",
                                              query_metering_hour=h, query_start_time=h,
                                              query_end_time=h + dt.timedelta(minutes=5),
                                              user_id=5001, user_name=user, role_name="ANALYST_ROLE",
                                              credits_used_compute=comp * share, credits_used_cloud_services=0.0,
                                              credits_used=comp * share))
    for k in range(1, 36):
        h = dt.datetime.combine(d(k), dt.time(10))
        au("WAREHOUSE_METERING_HISTORY", dict(start_time=h, end_time=h + dt.timedelta(hours=1), warehouse_id=1007,
                                              warehouse_name="WH_ADAPTIVE_B", credits_used=2.0, credits_used_compute=2.0,
                                              credits_used_cloud_services=0.0, credits_attributed_compute_queries=None))
        # the same hour in the billing views, so the audit ties out to the bill
        au("METERING_HISTORY", dict(service_type="WAREHOUSE_METERING", start_time=h, end_time=h + dt.timedelta(hours=1),
                                    entity_id=1007, entity_type="WAREHOUSE", name="WH_ADAPTIVE_B",
                                    credits_used_compute=2.0, credits_used_cloud_services=0.0, credits_used=2.0))
        day_rows = [r for r in w.rows[("account_usage", "METERING_DAILY_HISTORY")]
                    if r["service_type"] == "WAREHOUSE_METERING" and r["usage_date"] == d(k)]
        if day_rows:
            for key in ("credits_used_compute", "credits_used", "credits_billed"):
                day_rows[0][key] += 2.0
        else:
            au("METERING_DAILY_HISTORY", dict(service_type="WAREHOUSE_METERING", usage_date=d(k), credits_used_compute=2.0,
                                              credits_used_cloud_services=0.0, credits_used=2.0,
                                              credits_adjustment_cloud_services=0.0, credits_billed=2.0))
        au("QUERY_METERING_HISTORY", dict(query_id=f"qb{k}", warehouse_id=1007, warehouse_name="WH_ADAPTIVE_B",
                                          query_metering_hour=h, query_start_time=h,
                                          query_end_time=h + dt.timedelta(minutes=5),
                                          user_id=5002, user_name="SVC_BI", role_name="BI_ROLE",
                                          credits_used_compute=1.9, credits_used_cloud_services=0.0, credits_used=1.9))

    # 4. anomalies: a 320-credit AI_SERVICES day on -8 (audit spike, Snowflake flags it: both) and on -15 (audit only);
    #    Snowflake alone flags -3. Other days: inside the range.
    tot = {}
    for r in w.rows[("account_usage", "METERING_DAILY_HISTORY")]:
        tot[r["usage_date"]] = tot.get(r["usage_date"], 0) + (r["credits_billed"] or 0)
    for back in (8, 15):
        au("METERING_DAILY_HISTORY", dict(service_type="AI_SERVICES", usage_date=d(back), credits_used_compute=320.0,
                                          credits_used_cloud_services=0.0, credits_used=320.0,
                                          credits_adjustment_cloud_services=0.0, credits_billed=320.0))
        tot[d(back)] = tot.get(d(back), 0) + 320.0
    for k in range(1, 31):
        day = d(k)
        actual = tot.get(day, 0.0)
        flag = k in (8, 3)
        au("ANOMALIES_DAILY", dict(date=day, anomaly_id=f"an{k}", is_anomaly=flag, actual_value=actual,
                                   upper_bound=actual * 0.7 if flag else 900.0, lower_bound=100.0, forecasted_value=270.0))

    # 5. compute pools (POOL_ML already has history)
    pools = [("POOL_ML", 9101, 2, 4, "GPU_NV_S", 0, None), ("SYSTEM_COMPUTE_POOL_CPU", 9002, 1, 1, "CPU_X64_S", 3600, None),
             ("POOL_APP", 9003, 1, 2, "CPU_X64_M", 7200, "APP_SEARCH")]
    for name, pid, mn, mx, fam, susp, app in pools:
        au("COMPUTE_POOLS", dict(name=name, id=pid, is_suspended=False, min_nodes=mn, max_nodes=mx, instance_family=fam,
                                 auto_suspend_secs=susp, auto_resume=True, created=t(200), last_resumed=t(1),
                                 last_altered=t(20), owner="SYSADMIN", owner_role_type="ROLE", is_exclusive=False,
                                 application_name=app, application_id=77 if app else None))
    au("COMPUTE_POOLS", dict(name="POOL_OLD", id=9004, is_suspended=True, min_nodes=1, max_nodes=1,
                             instance_family="CPU_X64_S", auto_suspend_secs=600, auto_resume=True, created=t(300),
                             deleted=t(5), owner="SYSADMIN", owner_role_type="ROLE", is_exclusive=False))
    for k in range(1, 31):
        au("SNOWPARK_CONTAINER_SERVICES_HISTORY", dict(start_time=t(k, 3), end_time=t(k, 4), compute_pool_name="POOL_ML",
                                                      compute_pool_id=9101, is_exclusive=False, credits_used=7.0))
        for pool, hours, cr in (("SYSTEM_COMPUTE_POOL_CPU", 2, 0.5), ("POOL_APP", 2, 0.6), ("POOL_DROPPED", 3, 0.5)):
            for hh in range(hours):
                au("SNOWPARK_CONTAINER_SERVICES_HISTORY", dict(start_time=t(k, 8 + hh), end_time=t(k, 9 + hh),
                                                              compute_pool_name=pool, compute_pool_id=9100,
                                                              is_exclusive=False, credits_used=cr))

    # 6. key pairs: CRITICAL ADMIN_BOB (old, used, admin), WARN SVC_ETL 2nd key (old, used), WARN DEV_HUGO (never used),
    #    WARN DEV_GINA (disabled), OK SVC_ETL 1st key, OK SVC_LEGACY expired; SVC_BI has an RSA key with no record
    keys = [(7101, "KEY_BOB", "ADMIN_BOB", "ACTIVE", 500, 2), (7102, "KEY_ETL_OLD", "SVC_ETL", "ACTIVE", 300, 1),
            (7103, "KEY_ETL_NEW", "SVC_ETL", "ACTIVE", 20, 0), (7104, "KEY_HUGO", "DEV_HUGO", "ACTIVE", 200, None),
            (7105, "KEY_GINA", "DEV_GINA", "ACTIVE", 100, 30), (7106, "KEY_LEGACY", "SVC_LEGACY", "EXPIRED", 900, 400)]
    for cid, name, user, status, age, used in keys:
        au("CREDENTIALS", dict(credential_id=cid, name=name, user_name=user, type="KEYPAIR", domain="KEYPAIR",
                               status=status, additional_details={"ALGORITHM": "RSA"}, created_by=user,
                               last_altered_by=user, created_on=t(age), last_used_on=t(used) if used is not None else None,
                               last_altered=t(age)))

    # 7. tags: COST_CENTER OK, TEAM (case variants) WARN, UNUSED_TAG WARN, DATA_OWNER + DataOwner look-alikes WARN,
    #    PROJECT (25 values, no list) WARN
    tags = [(8201, "COST_CENTER", ["FIN", "ENG"]), (8202, "TEAM", None), (8203, "UNUSED_TAG", None),
            (8204, "DATA_OWNER", ["A", "B"]), (8205, "DataOwner", ["A", "B"]), (8206, "PROJECT", None)]
    for tid, name, allowed in tags:
        au("TAGS", dict(tag_id=tid, tag_name=name, tag_schema_id=7, tag_schema="TAGS", tag_database_id=3,
                        tag_database="GOV_DB", tag_owner="SYSADMIN", created=t(200), last_altered=t(200),
                        allowed_values=allowed, owner_role_type="ROLE"))

    def ref(tag, val, obj):
        au("TAG_REFERENCES", dict(tag_database="GOV_DB", tag_schema="TAGS", tag_id=8200, tag_name=tag, tag_value=val,
                                  object_database="ANALYTICS_DB", object_schema="CORE", object_id=1, object_name=obj,
                                  domain="TABLE", apply_method="MANUAL"))
    for i, v in enumerate(["FIN", "ENG", "FIN"]):
        ref("COST_CENTER", v, f"T{i}")
    for i, v in enumerate(["Finance", "finance", "Sales"]):
        ref("TEAM", v, f"T{i}")
    for i in range(3):
        ref("DATA_OWNER", "A", f"T{i}")
        ref("DataOwner", "B", f"T{i}")
    for i in range(25):
        ref("PROJECT", f"P{i}", f"T{i}")

    # 8. columns per database (ANALYTICS_DB and RAW_DB have sensitive tags already; SANDBOX_DB has none and 80 columns)
    for db, sch, tbl, ncols in (("ANALYTICS_DB", "CORE", "CUSTOMERS", 60), ("RAW_DB", "LANDING", "CUSTOMERS_RAW", 60),
                                ("SANDBOX_DB", "SCRATCH", "TMP1", 80), ("DEV_DB", "PUBLIC", "T1", 12),
                                ("ANALYTICS_DB", "INFORMATION_SCHEMA", "TABLES", 40)):
        for c in range(ncols):
            au("COLUMNS", dict(table_catalog=db, table_schema=sch, table_name=tbl, column_name=f"C{c}", data_type="TEXT",
                               ordinal_position=c + 1, is_nullable="YES", kind="COLUMN"))

    # 9. marketplace: L1 read (OK), L2 unread 40 EUR (WARN), L3 unread 1500 EUR (CRITICAL)
    for lst, db, cur, charge in (("GZ1.READ_LISTING", "ANALYTICS_DB", "EUR", 120.0),
                                 ("GZ2.QUIET_LISTING", "PARTNER_DATA", "EUR", 40.0),
                                 ("GZ3.BIG_LISTING", "MARKET_WEATHER", "EUR", 1500.0)):
        for back, ctype, amt in ((10, "FIXED", charge), (4, "VARIABLE", charge / 10)):
            w.add("data_sharing_usage", "MARKETPLACE_PAID_USAGE_DAILY", dict(
                report_date=t(back - 2), usage_date=t(back, 0), provider_name="Provider", provider_account_name="PROV",
                provider_account_locator="AB12345", provider_organization_name="PROVORG",
                listing_display_name=lst.split(".")[1], listing_global_name=lst, database_name=db, charge_type=ctype,
                units="10", unit_price=amt / 10, charge=amt, currency=cur))

    # 10. backup and snapshot sets (23 USD per TB-month): SET_OK has a policy, SET_MID none (WARN), SET_BIG none
    #     (CRITICAL), SET_GONE deleted, SNAP_OLD is a deprecated snapshot set (WARN)
    TB = 1024 ** 4
    sets = [(9501, "SET_OK", "BP_DAILY", 2 * TB, 0.2 * TB, None), (9502, "SET_MID", None, 3 * TB, 0.5 * TB, None),
            (9503, "SET_BIG", None, 30 * TB, 2 * TB, None), (9504, "SET_GONE", None, 0.01 * TB, 0.0, t(3))]
    for sid, name, pol, logical, inc, deleted in sets:
        au("BACKUP_SETS", dict(id=sid, name=name, schema_id=7, schema_name="BACKUPS", catalog_id=3, catalog_name="GOV_DB",
                               object_kind="TABLE", object_id=5007, object_name="ORDERS", object_schema_name="CORE",
                               object_catalog_name="ANALYTICS_DB", backup_policy_name=pol, owner="SYSADMIN",
                               owner_role_type="ROLE", created=t(100), last_altered=t(10), deleted=deleted))
        for i in range(3):
            au("BACKUP_STORAGE_USAGE", dict(backup_set_id=sid, backup_id=f"{sid}-{i}", logical_bytes=int(logical + i * inc),
                                            incremental_bytes_from_previous_backup=int(inc) if i else 0,
                                            decremental_bytes_from_previous_backup=0))
    au("SNAPSHOT_SETS", dict(id=9601, name="SNAP_OLD", schema_id=7, schema_name="BACKUPS", catalog_id=3,
                             catalog_name="GOV_DB", object_kind="TABLE", object_name="ORDERS", owner="SYSADMIN",
                             owner_role_type="ROLE", created=t(400)))
    for i in range(2):
        au("SNAPSHOT_STORAGE_USAGE", dict(snapshot_set_id=9601, snapshot_id=f"9601-{i}", logical_bytes=int(1 * TB),
                                          incremental_bytes_from_previous_snapshot=int(0.1 * TB) if i else 0,
                                          decremental_bytes_from_previous_snapshot=0))

    # 11. data metric functions: ANALYTICS_DB 1 of 11 tables (low coverage, WARN); RAW_DB none but a sensitive table
    #     (WARN); DEV_DB all suspended (WARN); SANDBOX_DB OK
    def dmf(db, sch, tbl, status, level="TABLE"):
        au("DATA_METRIC_FUNCTION_REFERENCES", dict(
            metric_database_name="SNOWFLAKE", metric_schema_name="CORE", metric_name="NULL_COUNT",
            argument_signature="(ARG_T TABLE(ARG_C1 NUMBER))", data_type="NUMBER", ref_database_name=db,
            ref_schema_name=sch, ref_entity_name=tbl, ref_entity_domain="TABLE", ref_id=f"{db}{sch}{tbl}",
            schedule="60 MINUTE", schedule_status=status, level=level))
    dmf("ANALYTICS_DB", "CORE", "CUSTOMERS", "STARTED")
    dmf("DEV_DB", "PUBLIC", "T1", "SUSPENDED_USER_TASK_MISSING_PRIVILEGES")

    # 12. shares: SHARE_PARTNER (existing) gets a sensitive table (CRITICAL unless masked); SHARE_VIEW reads it through
    #     a view (one level down); SHARE_ORDERS shares ORDERS, whose sensitive column has no masking policy (CRITICAL); SHARE_CLEAN shares an untagged
    #     table (OK)
    def gts(share, obj_db, obj_sch, obj, priv="SELECT", on="TABLE"):
        au("GRANTS_TO_SHARES", dict(created_on=t(50), modified_on=t(50), privilege=priv, granted_on=on, object_name=obj,
                                    object_database=obj_db, object_schema=obj_sch, share_name=share, granted_by="SYSADMIN",
                                    granted_by_role_type="ROLE"))
    gts("SHARE_PARTNER", "ANALYTICS_DB", "CORE", "CUSTOMERS")
    gts("SHARE_PARTNER", "ANALYTICS_DB", "CORE", "ANALYTICS_DB", priv="USAGE", on="DATABASE")
    gts("SHARE_CLEAN", "SANDBOX_DB", "SCRATCH", "TMP_A")
    gts("SHARE_ORDERS", "ANALYTICS_DB", "CORE", "ORDERS")
    gts("SHARE_VIEW", "ANALYTICS_DB", "MARTS", "V_CUSTOMERS", on="VIEW")
    au("OBJECT_DEPENDENCIES", dict(referenced_database="ANALYTICS_DB", referenced_schema="CORE",
                                   referenced_object_name="CUSTOMERS", referenced_object_id=5001,
                                   referenced_object_domain="TABLE", referencing_database="ANALYTICS_DB",
                                   referencing_schema="MARTS", referencing_object_name="V_CUSTOMERS",
                                   referencing_object_id=5099, referencing_object_domain="VIEW", dependency_type="BY_ID"))


def add_cold_cache_day(w) -> None:
    """A WH_ML day with 15 statements, most scanning cold: CRITICAL on cache reuse, under the 20-query floor."""
    day = w.as_of - dt.timedelta(days=1)
    for i in range(11):
        start = dt.datetime.combine(day, dt.time(3, i))
        w.au("QUERY_HISTORY", dict(
            query_id=f"cold-{i}", query_type="SELECT", user_name="ANALYST_DAN", role_name="ANALYST_ROLE",
            warehouse_id=1006, warehouse_name="WH_ML", execution_status="SUCCESS", start_time=start,
            end_time=start + dt.timedelta(minutes=1), total_elapsed_time=60000, execution_time=55000,
            compilation_time=200, queued_provisioning_time=0, bytes_scanned=5 * 1024 ** 4,
            percentage_scanned_from_cache=0.0, partitions_scanned=900, partitions_total=1000))
