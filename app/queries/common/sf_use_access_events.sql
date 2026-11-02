-- ACCESS_HISTORY flattened to one event per query x object x kind (read, write, ddl). Columns: query_id,
-- query_start_time, usage_date, user_name, kind, object_domain, object_id, object_name, is_table_like,
-- ddl_operation. sf_use_access_seen holds access_rows. Only ids, names and the DDL operation, never query text.
sf_use_ah AS (
  SELECT ah.query_id, ah.query_start_time, ah.user_name, ah.base_objects_accessed, ah.direct_objects_accessed,
         ah.objects_modified, ah.object_modified_by_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah
  WHERE ah.query_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND ah.query_start_time < __AS_OF_DATE__
),
sf_use_raw AS (
  SELECT a.query_id, a.query_start_time, a.user_name, 'read' AS kind,
         UPPER(f.value:"objectDomain"::STRING) AS object_domain, f.value:"objectId"::NUMBER AS object_id,
         UPPER(f.value:"objectName"::STRING) AS object_name, CAST(NULL AS VARCHAR) AS ddl_operation
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'read',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER,
         UPPER(f.value:"objectName"::STRING), CAST(NULL AS VARCHAR)
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  -- table-like objects are already in base_objects_accessed; views, stages, functions, streams are not
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'write',
         UPPER(f.value:"objectDomain"::STRING), f.value:"objectId"::NUMBER,
         UPPER(f.value:"objectName"::STRING), CAST(NULL AS VARCHAR)
  FROM sf_use_ah a, LATERAL FLATTEN(input => a.objects_modified) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, a.user_name, 'ddl',
         UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER,
         UPPER(a.object_modified_by_ddl:"objectName"::STRING),
         UPPER(a.object_modified_by_ddl:"operationType"::STRING)
  FROM sf_use_ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
sf_use_raw_t AS (
  SELECT r.*, r.object_domain IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE',
                                  'MATERIALIZED VIEW') AS is_table_like
  FROM sf_use_raw r
),
sf_use_events AS (
  SELECT DISTINCT r.query_id, r.query_start_time, DATE(r.query_start_time) AS usage_date, r.user_name, r.kind,
         r.object_domain, r.object_id, r.object_name, r.is_table_like, r.ddl_operation
  FROM sf_use_raw_t r
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  LEFT JOIN sf_use_raw_t w
    ON r.kind = 'read' AND w.kind = 'write' AND w.query_id = r.query_id
   AND w.is_table_like = r.is_table_like AND w.object_id = r.object_id
  WHERE w.query_id IS NULL
),
sf_use_access_seen AS (
  SELECT COUNT(*) AS access_rows FROM sf_use_ah
),
sf_use_access_events AS (
  SELECT * FROM sf_use_events
)
