"""Fake views and rows for the cost-gap checks (container costs outside pools, Openflow, notebook runtime,
model serving, archive retrieval, catalog-linked databases).

Columns and types are the documented ones. `add(world)` runs after batch3_data.add; each check gets OK and WARN
or CRITICAL rows. This module is the one place that defines SERVICES, BLOCK_STORAGE_HISTORY,
INTERNAL_DATA_TRANSFER_HISTORY and NOTEBOOKS_CONTAINER_RUNTIME_HISTORY; other fake modules only add rows to them.
POOL_ML is compute pool 9101, as in data.py. STORAGE_USAGE needs an ARCHIVE_STORAGE_RETRIEVAL_TEMP_BYTES:n column.
The model-serving growth test reads only when the window before starts on or after 25 Aug 2026.
"""
from __future__ import annotations

import datetime as dt

GB = 1024 ** 3

AU = {
    "SERVICES": "SERVICE_ID:n SERVICE_NAME:s SERVICE_CATALOG_ID:n SERVICE_CATALOG:s SERVICE_SCHEMA_ID:n SERVICE_SCHEMA:s "
        "SERVICE_OWNER:s SERVICE_OWNER_ROLE_TYPE:s COMPUTE_POOL_ID:n COMPUTE_POOL_NAME:s DNS_NAME:s MIN_READY_INSTANCES:n "
        "MIN_INSTANCES:n MAX_INSTANCES:n AUTO_RESUME:b QUERY_WAREHOUSE:s CREATED:t LAST_ALTERED:t LAST_RESUMED:t "
        "LAST_SUSPENDED:t AUTO_SUSPEND_SECS:n DELETED:t COMMENT:s IS_JOB:b IS_ASYNC_JOB:b",
    "BLOCK_STORAGE_HISTORY": "USAGE_DATE:t STORAGE_TYPE:s COMPUTE_POOL_NAME:s COMPUTE_POOL_ID:n BYTES:n "
        "ADDITIONAL_IOPS:n ADDITIONAL_THROUGHPUT:n",
    "INTERNAL_DATA_TRANSFER_HISTORY": "START_TIME:t END_TIME:t TRANSFER_TYPE:s COMPUTE_POOL_NAME:s BYTES_TRANSFERRED:n",
    "OPENFLOW_USAGE_HISTORY": "START_TIME:t END_TIME:t DATA_PLANE_ID:s DATA_PLANE_TYPE:s DATA_PLANE_CREDITS_USED:f "
        "RUNTIME_KEY:s RUNTIME_NAME:s RUNTIME_CREDITS_USED:f",
    "NOTEBOOKS_CONTAINER_RUNTIME_HISTORY": "START_TIME:t END_TIME:t NOTEBOOK_NAME:s NOTEBOOK_ID:n USER_NAME:s USER_ID:n "
        "COMPUTE_POOL_NAME:s COMPUTE_POOL_ID:n SERVICE_NAME:s SERVICE_ID:n NOTEBOOK_EXECUTION_TIME_SECS:n CREDITS:f",
    "MODEL_SERVING_USAGE_HISTORY": "INVOCATION_TYPE:s START_TIME:t END_TIME:t DATABASE_ID:n DATABASE_NAME:s SCHEMA_ID:n "
        "SCHEMA_NAME:s MODEL_ID:n MODEL_NAME:s MODEL_VERSION_ID:n MODEL_VERSION_NAME:s USER_NAME:s CREDITS:f "
        "COMPUTE_POOL_ID:n COMPUTE_POOL_NAME:s SERVICE_ID:n SERVICE_NAME:s WORKLOAD_TYPE:s FUNCTION_NAME:s QUERY_ID:s "
        "WAREHOUSE_ID:n QUERY_TAG:s",
    "ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY": "START_TIME:t END_TIME:t OBJECT_TYPE:s OBJECT_ID:n OBJECT_NAME:s "
        "SCHEMA_ID:n SCHEMA_NAME:s DATABASE_ID:n DATABASE_NAME:s BYTES:n ARCHIVE_STORAGE_TIER:s",
    "CATALOG_LINKED_DATABASE_USAGE_HISTORY": "START_TIME:t END_TIME:t DATABASE_ID:n DATABASE_NAME:s "
        "CREDITS_USED_COMPUTE:f CREDITS_USED_CLOUD_SERVICES:f CREDITS_USED:f",
}
OU: dict = {}
DSU: dict = {}
SHOW: dict = {}
SHOW_PRE: dict = {}


def add(w) -> None:
    """Rows for every new check: OK, WARN and CRITICAL where the check has the levels."""
    def t(back, h=9):
        return dt.datetime.combine(w.as_of - dt.timedelta(days=back), dt.time(h))

    au = w.au

    def hour_row(view, back, hour, **kw):
        au(view, dict(start_time=t(back, hour), end_time=t(back, hour) + dt.timedelta(hours=1), **kw))

    # 1. containers outside pool credits.
    #    POOL_ML runs and holds volumes (OK); POOL_STOPPED holds 200 GB and used no credits (WARN); POOL_ALWAYS bills every
    #    hour with a service that never suspends (WARN); POOL_APP has a service with 2 minimum instances; snapshots grow
    #    20 -> 60 GB (WARN).
    pools = [("POOL_ML", 9101), ("POOL_STOPPED", 9201), ("POOL_ALWAYS", 9202), ("POOL_APP", 9003)]
    for back in range(1, 61):
        for name, pid, gb in (("POOL_ML", 9101, 50), ("POOL_STOPPED", 9201, 200), ("POOL_ALWAYS", 9202, 20)):
            au("BLOCK_STORAGE_HISTORY", dict(usage_date=t(back, 0), storage_type="BLOCK_STORAGE", compute_pool_name=name,
                                             compute_pool_id=pid, bytes=int(gb * GB), additional_iops=500 if name == "POOL_ML" else 0,
                                             additional_throughput=100 if name == "POOL_ML" else 0))
        au("BLOCK_STORAGE_HISTORY", dict(usage_date=t(back, 0), storage_type="SNAPSHOT", bytes=int((60 if back <= 30 else 20) * GB)))
    for back in range(1, 31):
        for hh in range(24):
            hour_row("SNOWPARK_CONTAINER_SERVICES_HISTORY", back, hh, compute_pool_name="POOL_ALWAYS", compute_pool_id=9202,
                     is_exclusive=False, credits_used=0.5)
        au("INTERNAL_DATA_TRANSFER_HISTORY", dict(start_time=t(back, 5), end_time=t(back, 6), transfer_type="SERVICE_FUNCTION",
                                                  compute_pool_name="POOL_ML", bytes_transferred=int(5 * GB)))
        au("INTERNAL_DATA_TRANSFER_HISTORY", dict(start_time=t(back, 6), end_time=t(back, 7), transfer_type="COMPUTE_POOL",
                                                  compute_pool_name="POOL_ML", bytes_transferred=int(1 * GB)))
    for sid, name, pool, pid, mn, susp, job, deleted in (
            (9301, "ML_API", "POOL_ML", 9101, 1, 600, False, None), (9302, "ML_BATCH_JOB", "POOL_ML", 9101, 1, 0, True, None),
            (9303, "ALWAYS_SVC", "POOL_ALWAYS", 9202, 1, 0, False, None), (9304, "APP_SVC", "POOL_APP", 9003, 2, 900, False, None),
            (9305, "OLD_SVC", "POOL_ML", 9101, 1, 0, False, t(4))):
        au("SERVICES", dict(service_id=sid, service_name=name, service_catalog="ML_DB", service_schema="SERVICES",
                            service_owner="SYSADMIN", service_owner_role_type="ROLE", compute_pool_id=pid,
                            compute_pool_name=pool, min_ready_instances=1, min_instances=mn, max_instances=mn + 1,
                            auto_resume=True, created=t(100), last_altered=t(20), last_resumed=t(1), auto_suspend_secs=susp,
                            deleted=deleted, is_job=job, is_async_job=False))

    # 2. Openflow: RT_ALWAYS bills every hour (WARN), RT_BATCH 2 h a day (OK), RT_SPIKE grew 10x (CRITICAL); the
    #    Snowflake-hosted total doubled (WARN); the BYOC total equals the three runtimes (service row is always OK)
    runtimes = {"RT_ALWAYS": ("rt-001", range(24), 0.5, 0.5), "RT_BATCH": ("rt-002", (2, 3), 1.0, 1.0),
                "RT_SPIKE": ("rt-003", (10, 11), 5.0, 0.5)}
    for back in range(1, 61):
        cur = back <= 30
        byoc = 0.0
        for name, (key, hours, cur_c, prev_c) in runtimes.items():
            c = cur_c if cur else prev_c
            for hh in hours:
                hour_row("OPENFLOW_USAGE_HISTORY", back, hh, data_plane_id="dp-1", data_plane_type="BYOC",
                         data_plane_credits_used=0.0, runtime_key=key, runtime_name=name, runtime_credits_used=c)
                byoc += c
        hour_row("METERING_HISTORY", back, 0, service_type="OPENFLOW_COMPUTE_BYOC", credits_used_compute=byoc,
                 credits_used_cloud_services=0.0, credits_used=byoc)
        sf = 1.0 if cur else 0.5
        hour_row("METERING_HISTORY", back, 1, service_type="OPENFLOW_COMPUTE_SNOWFLAKE", credits_used_compute=sf,
                 credits_used_cloud_services=0.0, credits_used=sf)

    # 3. notebook runtime: NB_FOREVER is up 24 h a day (WARN), NB_SHORT 2 h a day and flat (OK), NB_SCHEDULED grew 150%
    #    (WARN), NB_TINY is under the spend floor (OK)
    for back in range(1, 61):
        cur = back <= 30
        for hh in range(24):
            if cur:
                hour_row("NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", back, hh, notebook_name="NB_FOREVER", notebook_id=7301,
                         user_name="ANALYST_DAN", user_id=5001, compute_pool_name="SYSTEM_COMPUTE_POOL_CPU",
                         compute_pool_id=9002, service_name="NB_SVC_1", service_id=9401,
                         notebook_execution_time_secs=600, credits=0.2)
        for hh in (9, 10):
            hour_row("NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", back, hh, notebook_name="NB_SHORT", notebook_id=7302,
                     user_name="ANALYST_CARA", user_id=5003, compute_pool_name="SYSTEM_COMPUTE_POOL_CPU",
                     compute_pool_id=9002, service_name="NB_SVC_2", service_id=9402, notebook_execution_time_secs=3000,
                     credits=0.2)
        hour_row("NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", back, 3, notebook_name="NB_SCHEDULED", notebook_id=7303,
                 compute_pool_name="POOL_ML", compute_pool_id=9101, service_name="NB_SVC_3", service_id=9403,
                 notebook_execution_time_secs=3400, credits=1.0 if cur else 0.4)
        hour_row("NOTEBOOKS_CONTAINER_RUNTIME_HISTORY", back, 12, notebook_name="NB_TINY", notebook_id=7304,
                 user_name="ANALYST_DAN", user_id=5001, compute_pool_name="SYSTEM_COMPUTE_POOL_CPU", compute_pool_id=9002,
                 service_name="NB_SVC_4", service_id=9404, notebook_execution_time_secs=60, credits=0.01)

    # 4. model serving: FRAUD_MODEL v1 is a service billing every hour (WARN), CHURN_MODEL v2 a job (OK), RANK_MODEL v1 a
    #    service up 2 h a day and flat (OK), SCORING_MODEL v3 on a warehouse doubled its calls (WARN)
    def model(inv, back, hh, name, mid, ver, vid, credits, **kw):
        base = dict(invocation_type=inv, database_id=3, database_name="ML_DB", schema_id=7, schema_name="MODELS",
                    model_id=mid, model_name=name, model_version_id=vid, model_version_name=ver, credits=credits)
        hour_row("MODEL_SERVING_USAGE_HISTORY", back, hh, **base, **kw)

    n = 0
    for back in range(1, 61):
        cur = back <= 30
        if cur:
            for hh in range(24):
                model("SPCS", back, hh, "FRAUD_MODEL", 7401, "V1", 7411, 0.1, compute_pool_id=9101, compute_pool_name="POOL_ML",
                      service_id=9501, service_name="FRAUD_SVC", workload_type="SERVICE")
        model("SPCS", back, 4, "CHURN_MODEL", 7402, "V2", 7412, 0.5, compute_pool_id=9101, compute_pool_name="POOL_ML",
              service_id=9502, service_name="CHURN_JOB", workload_type="JOB")
        for hh in (13, 14):
            model("SPCS", back, hh, "RANK_MODEL", 7403, "V1", 7413, 0.3, compute_pool_id=9101, compute_pool_name="POOL_ML",
                  service_id=9503, service_name="RANK_SVC", workload_type="SERVICE")
        if cur or back % 2 == 0:
            n += 1
            model("WAREHOUSE", back, 15, "SCORING_MODEL", 7404, "V3", 7414, 0.15, user_name="ANALYST_DAN" if n % 2 else "SVC_BI",
                  function_name="PREDICT", query_id=f"ms{n}", warehouse_id=1001, workload_type="WAREHOUSE_INFERENCE")

    # 5. archive retrieval: ORDERS_HIST pulled back on 5 days (WARN), EVENTS_OLD 500 GB from COLD (WARN), COOL_BIG 300 GB
    #    from COOL (WARN, any tier), ARCH_OK once (OK);
    #    the services row prices 30 days of archive writes plus file processing and lifecycle runs (OK)
    for back in (2, 5, 8, 11, 14):
        hour_row("ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY", back, 7, object_type="TABLE", object_id=7501,
                 object_name="ORDERS_HIST", schema_id=7, schema_name="CORE", database_id=3, database_name="ANALYTICS_DB",
                 bytes=int(2 * GB), archive_storage_tier="COOL")
    hour_row("ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY", 6, 7, object_type="TABLE", object_id=7502, object_name="EVENTS_OLD",
             schema_id=7, schema_name="CORE", database_id=3, database_name="ANALYTICS_DB", bytes=int(500 * GB),
             archive_storage_tier="COLD")
    hour_row("ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY", 7, 7, object_type="TABLE", object_id=7504, object_name="COOL_BIG",
             schema_id=7, schema_name="CORE", database_id=3, database_name="ANALYTICS_DB", bytes=int(300 * GB),
             archive_storage_tier="COOL")
    hour_row("ARCHIVE_STORAGE_DATA_RETRIEVAL_USAGE_HISTORY", 9, 7, object_type="TABLE", object_id=7503, object_name="ARCH_OK",
             schema_id=8, schema_name="LANDING", database_id=4, database_name="RAW_DB", bytes=int(1 * GB),
             archive_storage_tier="COOL")
    for back in range(1, 31):
        hour_row("METERING_HISTORY", back, 2, service_type="ARCHIVE_STORAGE_WRITE", credits_used_compute=0.5,
                 credits_used_cloud_services=0.0, credits_used=0.5)
        if back <= 10:
            hour_row("METERING_HISTORY", back, 3, service_type="ARCHIVE_STORAGE_RETRIEVAL_FILE_PROCESSING",
                     credits_used_compute=0.1, credits_used_cloud_services=0.0, credits_used=0.1)
            hour_row("METERING_HISTORY", back, 4, service_type="STORAGE_LIFECYCLE_POLICY_EXECUTION",
                     credits_used_compute=0.2, credits_used_cloud_services=0.0, credits_used=0.2)

    # 6. catalog-linked databases: CLDB_ACTIVE is read (OK), CLDB_IDLE spends 30 credits and nobody reads it (WARN),
    #    CLDB_SMALL is under the spend floor (OK)
    for back in range(1, 61):
        for did, name, comp, cs in ((6001, "CLDB_ACTIVE", 2.0, 0.1), (6002, "CLDB_IDLE", 1.0, 0.05), (6003, "CLDB_SMALL", 0.01, 0.0)):
            hour_row("CATALOG_LINKED_DATABASE_USAGE_HISTORY", back, 1, database_id=did, database_name=name,
                     credits_used_compute=comp, credits_used_cloud_services=cs, credits_used=comp + cs)
    for back in range(1, 11):
        au("ACCESS_HISTORY", dict(query_id=f"cl{back}", query_start_time=t(back, 11), user_name="ANALYST_DAN",
                                  direct_objects_accessed=[{"objectName": "CLDB_ACTIVE.PUBLIC.T1", "objectId": 6101,
                                                            "objectDomain": "Table"}],
                                  base_objects_accessed=[{"objectName": "CLDB_ACTIVE.PUBLIC.T1", "objectId": 6101,
                                                          "objectDomain": "Table"}]))
