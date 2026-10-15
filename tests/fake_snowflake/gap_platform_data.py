"""Fake views and rows for the platform-gap checks (stale stage files, idle compute pools, silent task failures,
silenced alerts, suspended dynamic tables that are read, Native App permissions).

Columns and types are the documented ones. `add(world)` runs after batch3_data.add; each check gets OK and WARN or
CRITICAL rows. SERVICES, NOTEBOOKS_CONTAINER_RUNTIME_HISTORY and CATALOG_LINKED_DATABASE_USAGE_HISTORY are defined in
gap_cost_data; here they get extra rows only. The catalog-linked database check reads the rows gap_cost_data adds.
"""
from __future__ import annotations

import datetime as dt

GB = 1024 ** 3
TB = 1024 ** 4

AU = {
    "STAGE_STORAGE_USAGE_DETAILS": "USAGE_DATE:d CATALOG_NAME:s CATALOG_ID:n SCHEMA_NAME:s SCHEMA_ID:n ENTITY_NAME:s "
        "STAGE_TYPE:s ENTITY_ID:n BYTES:n FILE_COUNT:n STAGE_CREATED:t STAGE_DROPPED:t CATALOG_CREATED:t "
        "CATALOG_DROPPED:t SCHEMA_CREATED:t SCHEMA_DROPPED:t COMMENT:s MAX_LAST_MODIFIED:t MIN_LAST_MODIFIED:t",
    # The view is missing from the catalog file; columns are the ones docs.snowflake.com lists.
    "TASKS": "CREATED:t LAST_ALTERED:t DELETED:t ID:s TASK_NAME:s TASK_DATABASE_ID:n TASK_DATABASE:s TASK_SCHEMA_ID:n "
        "TASK_SCHEMA:s TASK_OWNER:s COMMENT:s WAREHOUSE:s SCHEDULE:s PREDECESSORS:j STATE:s DEFINITION:s CONDITION:s "
        "ALLOW_OVERLAPPING_EXECUTION:b ERROR_INTEGRATION:s LAST_COMMITTED:t LAST_SUSPENDED:t OWNER_ROLE_TYPE:s "
        "INSTANCE_ID:n CONFIG:s TASK_RELATIONS:j TASK_RELATIONS_IDS:j LAST_SUSPENDED_REASON:s SUCCESS_INTEGRATION:s "
        "SCHEDULING_MODE:s TARGET_COMPLETION_INTERVAL:s EXECUTE_AS_USER_ID:n OVERLAP_POLICY:s CREATED_BY_USER_ID:n",
    "APPLICATION_SPECIFICATIONS": "ID:n NAME:s APPLICATION_ID:n APPLICATION_NAME:s CREATED:t DELETED:t TYPE:s "
        "SEQUENCE_NUMBER:n REQUESTED_ON:t STATUS:s STATUS_UPDATED_ON:t LABEL:s DESCRIPTION:s DEFINITION:s",
}
OU: dict = {}
DSU: dict = {}
SHOW = {
    "alerts": "created_on:t name:s database_name:s schema_name:s owner:s comment:s warehouse:s schedule:s state:s "
        "condition:s action:s owner_role_type:s runbook:s config:s was_auto_suspended:s",
    # `text` (the create statement) is left out on purpose: no check reads it.
    "dynamic_tables": "created_on:t name:s database_name:s schema_name:s cluster_by:s rows:n bytes:n owner:s "
        "target_lag:s scheduler:s refresh_mode:s refresh_mode_reason:s warehouse:s comment:s automatic_clustering:s "
        "scheduling_state:s last_suspended_on:t is_clone:s is_replica:s is_iceberg:s data_timestamp:t "
        "owner_role_type:s immutable_where:s execute_as_user:s",
    "services": "name:s status:s database_name:s schema_name:s owner:s compute_pool:s dns_name:s current_instances:n "
        "target_instances:n min_ready_instances:n min_instances:n max_instances:n auto_resume:s "
        "external_access_integrations:s created_on:t updated_on:t resumed_on:t suspended_on:t auto_suspend_secs:n "
        "comment:s owner_role_type:s query_warehouse:s is_job:s is_async_job:s spec_digest:s is_upgrading:s "
        "managing_object_domain:s managing_object_name:s",
}
SHOW_PRE = {"SHOW ALERTS": "alerts", "SHOW DYNAMIC TABLES": "dynamic_tables", "SHOW SERVICES": "services"}


def add(w) -> None:
    """Rows for every new check: OK, WARN and CRITICAL where the check has the levels."""
    def t(back, h=9):
        return dt.datetime.combine(w.as_of - dt.timedelta(days=back), dt.time(h))

    def d(back):
        return w.as_of - dt.timedelta(days=back)

    au = w.au
    users = {r["name"]: r["user_id"] for r in w.rows[("account_usage", "USERS")]}

    # 1. stale stage files (23 USD per TB-month; latest day is as_of - 2). LOAD_STAGE is fresh (OK); OLD_EXPORT_STAGE
    #    holds 1.5 TB untouched for 120 days (WARN, about 35 USD); EXPORT_STAGE 6 TB for 200 days (CRITICAL by cost);
    #    ORPHAN_STAGE sits in a dropped schema (CRITICAL); user stages: ANALYST_DAN fresh (OK), EX_IVAN deleted (WARN),
    #    DEV_GINA disabled but small (owner_gone, OK by cost), LONG_GONE not listed (WARN); ORDERS_RAW table stage (OK);
    #    ORPHAN_STAGE is small (WARN), ORPHAN_BIG_STAGE is 6 TB (CRITICAL by cost); GAP_STAGE has no row on the latest day
    #    but one the day before (kept, WARN); EMPTIED_STAGE last row is 4 days before the latest (left out)
    latest = d(2)
    stages = [  # type, id, db, schema, name, bytes, newest age in days, extra
        ("Internal Named", 6601, "RAW_DB", "LANDING", "LOAD_STAGE", 500 * GB, 2, {}),
        ("Internal Named", 6602, "RAW_DB", "LANDING", "OLD_EXPORT_STAGE", int(1.5 * TB), 120, {}),
        ("Internal Named", 6603, "ANALYTICS_DB", "CORE", "EXPORT_STAGE", 6 * TB, 200, {}),
        ("Internal Named", 6604, "RAW_DB", "TMP_SCHEMA", "ORPHAN_STAGE", 50 * GB, 30, {"schema_dropped": t(20)}),
        ("Internal Named", 6605, "RAW_DB", "TMP_SCHEMA", "ORPHAN_BIG_STAGE", 6 * TB, 30, {"schema_dropped": t(20)}),
        ("Internal Named", 6698, "RAW_DB", "LANDING", "GAP_STAGE", 2 * TB, 100, {"only_before": 3, "skip_latest": True}),
        ("User", users["ANALYST_DAN"], None, None, "ANALYST_DAN", 1 * GB, 3, {}),
        ("User", users["EX_IVAN"], None, None, "EX_IVAN", 400 * GB, 150, {}),
        ("User", users["DEV_GINA"], None, None, "DEV_GINA", 100 * GB, 90, {}),
        ("User", 6690, None, None, "LONG_GONE", 300 * GB, 400, {}),
        ("Table", 5001, "RAW_DB", "LANDING", "ORDERS_RAW", 20 * GB, 1, {}),
        ("Internal Named", 6699, "RAW_DB", "LANDING", "EMPTIED_STAGE", 100 * GB, 5, {"only_before": 6}),
    ]
    for typ, sid, db, sch, name, nbytes, age, extra in stages:
        for k in range(2, 12):
            if extra.get("only_before") and k < extra["only_before"]:
                continue
            if extra.get("skip_latest") and k == 2:
                continue
            newest = dt.datetime.combine(latest, dt.time(0)) - dt.timedelta(days=age)
            au("STAGE_STORAGE_USAGE_DETAILS", dict(
                usage_date=d(k), catalog_name=db, catalog_id=3 if db else None, schema_name=sch, schema_id=7 if sch else None,
                entity_name=name, stage_type=typ, entity_id=sid, bytes=nbytes, file_count=max(1, nbytes // (50 * 1024 ** 2)),
                stage_created=t(300), stage_dropped=None, catalog_created=t(400) if db else None, catalog_dropped=None,
                schema_created=t(390) if sch else None, schema_dropped=extra.get("schema_dropped"),
                max_last_modified=newest, min_last_modified=newest - dt.timedelta(days=30)))

    # 2. compute pools with no running service. POOL_SVC_STOPPED: its only service was dropped 15 days ago and the pool
    #    kept billing 4 h a day (WARN); POOL_NEVER never had a service and bills 3 credits an hour (CRITICAL, idle all
    #    window); POOL_LIVE has a live service (OK); POOL_JOBS runs a job service (not assessed); POOL_NB has no service
    #    but a notebook billed in the same hours (OK). POOL_DROPPED (gap_cost_data and older rows) reads WARN.
    for pid, name, susp in ((9701, "POOL_SVC_STOPPED", 300), (9703, "POOL_LIVE", 600)):
        au("COMPUTE_POOLS", dict(name=name, id=pid, is_suspended=False, min_nodes=1, max_nodes=2, instance_family="CPU_X64_S",
                                 auto_suspend_secs=susp, auto_resume=True, created=t(200), last_resumed=t(1), last_altered=t(20),
                                 owner="SYSADMIN", owner_role_type="ROLE", is_exclusive=False))
    services = [  # id, name, pool, pool id, job, deleted, created
        (9601, "SVC_STOPPED", "POOL_SVC_STOPPED", 9701, False, t(15), t(100)),
        (9602, "SVC_LIVE", "POOL_LIVE", 9703, False, None, t(100)),
        (9603, "JOB_ETL", "POOL_JOBS", 9704, True, None, t(10)),
        (9604, "SVC_SUSPENDED", "POOL_LIVE", 9703, False, None, t(100)),
    ]
    for sid, name, pool, pid, job, deleted, created in services:
        au("SERVICES", dict(service_id=sid, service_name=name, service_catalog="ML_DB", service_schema="SERVICES",
                            service_owner="SYSADMIN", service_owner_role_type="ROLE", compute_pool_id=pid,
                            compute_pool_name=pool, min_ready_instances=1, min_instances=1, max_instances=1, auto_resume=True,
                            created=created, last_altered=t(20), last_resumed=t(90) if not job else None, last_suspended=t(5) if name == "SVC_SUSPENDED" else None,
                            auto_suspend_secs=600, deleted=deleted, is_job=job, is_async_job=False))
    for k in range(1, 31):
        for pool, pid, hours, cr in (("POOL_SVC_STOPPED", 9701, (10, 11, 12, 13), 2.0), ("POOL_NEVER", 9702, (5,), 3.0),
                                     ("POOL_LIVE", 9703, (6,), 1.0), ("POOL_JOBS", 9704, (7,), 1.0),
                                     ("POOL_NB", 9705, (8,), 1.0)):
            for hh in hours:
                au("SNOWPARK_CONTAINER_SERVICES_HISTORY", dict(
                    start_time=t(k, hh), end_time=t(k, hh + 1), compute_pool_name=pool, compute_pool_id=pid,
                    is_exclusive=False, credits_used=cr))
        au("NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", dict(
            start_time=t(k, 8), end_time=t(k, 9), notebook_name="NB_ON_POOL_NB", notebook_id=7351, user_name="ANALYST_DAN",
            user_id=users["ANALYST_DAN"], compute_pool_name="POOL_NB", compute_pool_id=9705, service_name="NB_SVC_9",
            service_id=9409, notebook_execution_time_secs=1800, credits=0.5))
    for name, pool, status, job in (("SVC_LIVE", "POOL_LIVE", "RUNNING", "false"), ("SVC_SUSPENDED", "POOL_LIVE", "SUSPENDED", "false"),
                                    ("JOB_ETL", "POOL_JOBS", "FAILED", "true")):
        w.show("services", dict(name=name, status=status, database_name="ML_DB", schema_name="SERVICES", owner="SYSADMIN",
                                compute_pool=pool, current_instances=1 if status == "RUNNING" else 0, target_instances=1,
                                min_instances=1, max_instances=1, auto_resume="true", created_on=t(100), is_job=job,
                                is_async_job="false", owner_role_type="ROLE"))

    # 3. tasks (ids match TASK_HISTORY.root_task_id). T_LOAD_ORDERS has an error integration (OK, its child fails a little);
    #    T_LOAD_CUSTOMERS fails with no integration or finalizer (CRITICAL); T_BUILD_MARTS is a child (not a row);
    #    T_FLAKY has a finalizer but was suspended by errors (WARN); T_SERVERLESS_REFRESH is owned by ACCOUNTADMIN (WARN);
    #    T_SERVERLESS_CLEAN is clean (OK); T_OLD_SUSPENDED is off and quiet (OK); T_HOURLY_CHECK runs as a deleted user
    #    (CRITICAL); T_GHOST_RUNAS runs as a user id USERS does not list (CRITICAL); T_OVERLAP allows all overlap on a
    #    warehouse (WARN); T_FLAKY is suspended by errors but that is judged in sf_task_suspended_or_stale (OK here)
    ivan = users["EX_IVAN"]
    tasks = [  # id, name, db, schema, owner, wh, schedule, preds, state, err integration, finalizer, susp reason, run-as, overlap
        ("8600", "T_LOAD_ORDERS", "RAW_DB", "LANDING", "ETL_ROLE", "WH_ETL", "USING CRON 0 1 * * * UTC", [], "started", "EMAIL_INT", None, None, users["SVC_ETL"], "NO_OVERLAP"),
        ("8601", "T_LOAD_CUSTOMERS", "RAW_DB", "LANDING", "ETL_ROLE", "WH_ETL", "USING CRON 30 1 * * * UTC", [], "started", None, None, None, users["SVC_ETL"], "NO_OVERLAP"),
        ("8602", "T_BUILD_MARTS", "ANALYTICS_DB", "MARTS", "DATA_ADMIN", "WH_ETL", None, ["RAW_DB.LANDING.T_LOAD_ORDERS"], "started", None, None, None, None, "NO_OVERLAP"),
        ("8603", "T_FLAKY", "ANALYTICS_DB", "MARTS", "DEV_ROLE", "WH_ADHOC", "60 MINUTE", [], "suspended", None, "ANALYTICS_DB.MARTS.T_FINALIZE", "SUSPENDED_DUE_TO_ERRORS", users["ANALYST_DAN"], "NO_OVERLAP"),
        ("8501", "T_SERVERLESS_REFRESH", "ANALYTICS_DB", "MARTS", "ACCOUNTADMIN", None, "USING CRON 0 2 * * * UTC", [], "started", "EMAIL_INT", None, None, users["SVC_ETL"], "NO_OVERLAP"),
        ("8502", "T_SERVERLESS_CLEAN", "ANALYTICS_DB", "MARTS", "DATA_ADMIN", None, "USING CRON 0 4 * * * UTC", [], "started", "EMAIL_INT", None, None, users["SVC_ETL"], "NO_OVERLAP"),
        ("8606", "T_OLD_SUSPENDED", "SANDBOX_DB", "SCRATCH", "DEV_ROLE", "WH_ADHOC", "USING CRON 0 5 * * * UTC", [], "suspended", None, None, "USER_SUSPENDED", users["ANALYST_DAN"], "NO_OVERLAP"),
        ("8607", "T_HOURLY_CHECK", "ANALYTICS_DB", "CORE", "SYSADMIN", "WH_BI", "60 MINUTE", [], "started", "EMAIL_INT", None, None, ivan, "NO_OVERLAP"),
        ("8608", "T_GHOST_RUNAS", "ANALYTICS_DB", "CORE", "SYSADMIN", "WH_BI", "60 MINUTE", [], "started", "EMAIL_INT", None, None, 987654, "NO_OVERLAP"),
        ("8790", "T_OVERLAP", "ANALYTICS_DB", "MARTS", "DATA_ADMIN", "WH_ETL", "60 MINUTE", [], "started", "EMAIL_INT", None, None, users["SVC_ETL"], "ALLOW_ALL_OVERLAP"),
    ]
    for tid, name, db, sch, owner, wh, sched, preds, state, err, fin, reason, runas, overlap in tasks:
        rel = {"Predecessors": preds}
        if fin:
            rel["FinalizerTask"] = fin
        au("TASKS", dict(created=t(300), last_altered=t(30), deleted=None, id=tid, task_name=name, task_database_id=3,
                         task_database=db, task_schema_id=7, task_schema=sch, task_owner=owner, warehouse=wh, schedule=sched,
                         predecessors=preds, state=state, allow_overlapping_execution=overlap != "NO_OVERLAP",
                         error_integration=err, last_committed=t(30), last_suspended=t(20) if state == "suspended" else None,
                         owner_role_type="ROLE", task_relations=rel, last_suspended_reason=reason,
                         execute_as_user_id=runas, overlap_policy=overlap))

    # 4. alerts (ALERT_LAG and ALERT_CREDITS evaluate every day already). ALERT_AUTO was auto-suspended 40 days ago and
    #    is still off (CRITICAL); ALERT_OLD_OFF is suspended with no history (WARN); ALERT_IDLE is started with a
    #    schedule and never evaluates (WARN); ALERT_HIDDEN runs in the history but SHOW does not list it (one
    #    NOT_ASSESSED row counting it)
    for name, state, sched, auto in (("ALERT_LAG", "started", "360 MINUTE", "false"), ("ALERT_CREDITS", "started", "360 MINUTE", "false"),
                                     ("ALERT_AUTO", "suspended", "60 MINUTE", "true"), ("ALERT_OLD_OFF", "suspended", "60 MINUTE", "false"),
                                     ("ALERT_IDLE", "started", "60 MINUTE", "false")):
        w.show("alerts", dict(created_on=t(200), name=name, database_name="ANALYTICS_DB", schema_name="CORE", owner="DATA_ADMIN",
                              warehouse="WH_ETL", schedule=sched, state=state, owner_role_type="ROLE", was_auto_suspended=auto))
    for k in range(1, 4):
        au("ALERT_HISTORY", dict(name="ALERT_HIDDEN", database_name="ANALYTICS_DB", schema_name="CORE", state="CONDITION_FALSE",
                                 error_code=None, error_message=None, scheduled_time=t(k, 6), completed_time=t(k, 6),
                                 scheduled_from="SCHEDULE", was_auto_suspended=False))
    for k in range(40, 46):
        au("ALERT_HISTORY", dict(name="ALERT_AUTO", database_name="ANALYTICS_DB", schema_name="CORE", state="FAILED",
                                 error_code=1003, error_message="syntax error", scheduled_time=t(k, 6),
                                 completed_time=t(k, 6), scheduled_from="SCHEDULE", was_auto_suspended=k == 40))

    # 5. dynamic tables. DAILY_SALES is fresh (OK); CUSTOMER_LTV is 14 h old on a 15 minute lag (WARN); DT_UNREAD_SMALL is
    #    suspended and unread (WARN); DT_UNREAD_BIG runs (OK); DT_SUSPENDED_READ is suspended and read by 3 queries
    #    (CRITICAL, reads counted after the suspension 12 days ago); DT_FULL_MODE is running (OK; full mode is judged in
    #    sf_dt_refresh_failures_and_lag); DT_MANUAL is suspended with the scheduler disabled (refreshed by hand, OK)
    dts = [  # name, lag, state, mode, reason, data timestamp
        ("DAILY_SALES", "1 hour", "RUNNING", "INCREMENTAL", None, dt.datetime.combine(w.as_of, dt.time(0)) - dt.timedelta(hours=1)),
        ("CUSTOMER_LTV", "15 minutes", "RUNNING", "INCREMENTAL", None, t(1, 10)),
        ("DT_UNREAD_SMALL", "1 hour", "SUSPENDED", "INCREMENTAL", None, t(20, 3)),
        ("DT_UNREAD_BIG", "1 hour", "RUNNING", "INCREMENTAL", None, dt.datetime.combine(w.as_of, dt.time(0)) - dt.timedelta(minutes=30)),
        ("DT_SUSPENDED_READ", "1 hour", "SUSPENDED", "INCREMENTAL", None, t(12, 3)),
        ("DT_FULL_MODE", "1 hour", "RUNNING", "FULL", "the query uses a non-deterministic function", dt.datetime.combine(w.as_of, dt.time(0)) - dt.timedelta(minutes=20)),
    ]
    for name, lag, state, mode, reason, ts in dts:
        w.show("dynamic_tables", dict(created_on=t(200), name=name, database_name="ANALYTICS_DB", schema_name="MARTS", owner="DATA_ADMIN",
                                      target_lag=lag, scheduler="ENABLE", refresh_mode=mode, refresh_mode_reason=reason,
                                      warehouse="WH_ETL", scheduling_state=state,
                                      last_suspended_on=t(12) if state == "SUSPENDED" else None, data_timestamp=ts,
                                      owner_role_type="ROLE"))
    w.show("dynamic_tables", dict(created_on=t(200), name="DT_MANUAL", database_name="ANALYTICS_DB", schema_name="MARTS",
                                  owner="DATA_ADMIN", target_lag="1 hour", scheduler="DISABLE", refresh_mode="INCREMENTAL",
                                  warehouse="WH_ETL", scheduling_state="SUSPENDED", last_suspended_on=t(12),
                                  data_timestamp=t(12, 3), owner_role_type="ROLE"))
    for k in range(3, 6):
        obj = [{"objectName": "ANALYTICS_DB.MARTS.DT_SUSPENDED_READ", "objectDomain": "Table", "objectId": 5201}]
        au("ACCESS_HISTORY", dict(query_id=f"01sr-{k}", query_start_time=t(k, 11), user_name="ANALYST_DAN",
                                  direct_objects_accessed=obj, base_objects_accessed=obj))

    # 6. Native Apps (DATA_APP_A..D have daily usage already). DATA_APP_A has nothing granted (OK); DATA_APP_B has an approved
    #    security integration (WARN); DATA_APP_C holds CREATE WAREHOUSE on the account (WARN); DATA_APP_D holds a SNOWFLAKE
    #    database role (WARN); APP_POWER has approved external access and USAGE on SNOWFLAKE, how IMPORTED PRIVILEGES is
    #    recorded (CRITICAL); APP_QUIET has approved external access and no app
    #    credits (WARN); APP_PENDING has a request waiting (OK, no approved access); a declined specification and a deleted one
    #    are not counted
    specs = [  # id, app id, app, type, status, deleted
        (8901, 8802, "DATA_APP_B", "SECURITY_INTEGRATION", "APPROVED", None),
        (8902, 8810, "APP_POWER", "EXTERNAL_ACCESS", "APPROVED", None),
        (8903, 8811, "APP_QUIET", "EXTERNAL_ACCESS", "APPROVED", None),
        (8904, 8812, "APP_PENDING", "EXTERNAL_ACCESS", "PENDING", None),
        (8905, 8803, "DATA_APP_C", "EXTERNAL_ACCESS", "DECLINED", None),
        (8906, 8801, "DATA_APP_A", "EXTERNAL_ACCESS", "APPROVED", t(5)),
    ]
    for sid, aid, app, typ, status, deleted in specs:
        au("APPLICATION_SPECIFICATIONS", dict(id=sid, name=f"SPEC_{sid}", application_id=aid, application_name=app, created=t(90),
                                              deleted=deleted, type=typ, sequence_number=1, requested_on=t(90), status=status,
                                              status_updated_on=t(80), label=f"Spec {sid}"))
    for app, priv, on, name in (("DATA_APP_C", "CREATE WAREHOUSE", "ACCOUNT", "FAKE_ACCOUNT"),
                                ("APP_POWER", "USAGE", "DATABASE", "SNOWFLAKE"),
                                ("DATA_APP_D", "USAGE", "DATABASE_ROLE", "SNOWFLAKE.USAGE_VIEWER"),
                                ("APP_POWER", "EXECUTE TASK", "ACCOUNT", "FAKE_ACCOUNT"),
                                ("APP_QUIET", "USAGE", "WAREHOUSE", "WH_ETL")):
        au("GRANTS_TO_ROLES", dict(created_on=t(80), modified_on=t(80), deleted_on=None, privilege=priv, granted_on=on, name=name,
                                   granted_to="APPLICATION", grantee_name=app, grant_option=False, granted_by="ACCOUNTADMIN",
                                   granted_by_role_type="ROLE"))
    for k in range(1, 31):
        au("APPLICATION_DAILY_USAGE_HISTORY", dict(application_name="APP_POWER", application_id=8810, listing_global_name="GZ8810",
                                                   usage_date=d(k), credits_used=0.3))
