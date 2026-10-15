-- query_id: sf_acct_object_counts
-- shims: DATABASES, SCHEMATA, TABLES, STAGES, PIPES, FUNCTIONS, PROCEDURES, SEQUENCES, FILE_FORMATS, USERS, ROLES, TASK_HISTORY
-- reads: INFORMATION_SCHEMA table functions DATABASES (view), SCHEMATA (view, per database), TABLES (view, STAGES (view, PIPES (view, FUNCTIONS (view, PROCEDURES (view, SEQUENCES (view, FILE_FORMATS (view, SHOW USERS, SHOW ROLES, TASK_HISTORY
-- fallback_note: the databases this role can see; dropped databases are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; the objects this role can see, in its own databases (not shared ones); dropped objects are not listed; the name stands in for ids; live users only; no password-change dates; the name stands in for the user id; account roles only (no database or instance roles); the name stands in for the role id; task runs for the last 7 days at most, up to 10,000 a day, only tasks this role owns or can monitor (MONITOR EXECUTION shows all)
-- pre: SHOW STREAMS IN ACCOUNT; SHOW TASKS IN ACCOUNT
WITH inv AS (
  SELECT 'DATABASE' AS object_type, IFF(is_transient = 'YES', 'TRANSIENT', 'PERMANENT') AS object_subtype, database_name AS db,
         'ACCOUNT_USAGE.DATABASES' AS source
  FROM __SHIM_DATABASES__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'SCHEMA', IFF(is_transient = 'YES', 'TRANSIENT', 'PERMANENT'), catalog_name, 'ACCOUNT_USAGE.SCHEMATA'
  FROM __SHIM_SCHEMATA__ WHERE deleted IS NULL AND schema_name <> 'INFORMATION_SCHEMA'
  UNION ALL
  SELECT IFF(table_type LIKE '%VIEW%', 'VIEW', 'TABLE'),
         CASE WHEN is_iceberg = 'YES' THEN 'ICEBERG TABLE'
              WHEN is_dynamic = 'YES' THEN 'DYNAMIC TABLE'
              WHEN is_hybrid = 'YES' THEN 'HYBRID TABLE'
              WHEN table_type = 'BASE TABLE' AND is_transient = 'YES' THEN 'TRANSIENT TABLE'
              ELSE table_type END,
         table_catalog, 'ACCOUNT_USAGE.TABLES'
  FROM __SHIM_TABLES__ WHERE deleted IS NULL AND table_schema <> 'INFORMATION_SCHEMA'
  UNION ALL
  SELECT 'STAGE', COALESCE(stage_type, 'UNKNOWN'), stage_catalog, 'ACCOUNT_USAGE.STAGES'
  FROM __SHIM_STAGES__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'PIPE', IFF(is_autoingest_enabled = 'YES', 'AUTO_INGEST', 'REST / MANUAL'), pipe_catalog, 'ACCOUNT_USAGE.PIPES'
  FROM __SHIM_PIPES__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'FUNCTION', UPPER(function_language), function_catalog, 'ACCOUNT_USAGE.FUNCTIONS'
  FROM __SHIM_FUNCTIONS__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'PROCEDURE', UPPER(procedure_language), procedure_catalog, 'ACCOUNT_USAGE.PROCEDURES'
  FROM __SHIM_PROCEDURES__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'SEQUENCE', 'SEQUENCE', sequence_catalog, 'ACCOUNT_USAGE.SEQUENCES'
  FROM __SHIM_SEQUENCES__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'FILE FORMAT', UPPER(file_format_type), file_format_catalog, 'ACCOUNT_USAGE.FILE_FORMATS'
  FROM __SHIM_FILE_FORMATS__ WHERE deleted IS NULL
  UNION ALL
  SELECT 'USER', COALESCE(UPPER(type), 'PERSON')
                 || IFF(COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE), ' (disabled)', ''),
         CAST(NULL AS VARCHAR), 'ACCOUNT_USAGE.USERS'
  FROM __SHIM_USERS__ WHERE deleted_on IS NULL
  UNION ALL
  SELECT 'ROLE', 'ROLE', CAST(NULL AS VARCHAR), 'ACCOUNT_USAGE.ROLES'
  FROM __SHIM_ROLES__ WHERE deleted_on IS NULL
  UNION ALL
  SELECT 'STREAM', UPPER(COALESCE("source_type", 'Table')) || ' / ' || UPPER(COALESCE("mode", 'DEFAULT')),
         "database_name", 'SHOW STREAMS'
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2)))
  UNION ALL
  SELECT 'TASK', UPPER("state") || IFF(NULLIF(TRIM("warehouse"), '') IS NULL, ' / serverless', ' / warehouse'),
         "database_name", 'SHOW TASKS'
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
inv_types AS (SELECT object_type FROM inv),
agg AS (
  SELECT object_type, object_subtype, COUNT(*) AS object_count, COUNT(DISTINCT db) AS database_count,
         MAX(source) AS source, CAST(NULL AS VARCHAR) AS reason
  FROM inv
  GROUP BY object_type, object_subtype
),
n_streams AS (SELECT COUNT_IF(object_type = 'STREAM') AS n FROM inv_types),
n_tasks AS (SELECT COUNT_IF(object_type = 'TASK') AS n FROM inv_types),
task_runs AS (
  SELECT COUNT(*) AS n FROM (SELECT 1 FROM __SHIM_TASK_HISTORY__ LIMIT 1)
),
-- SHOW lists only what the role can see, so an empty SHOW is never read as "none exist".
gaps AS (
  SELECT 'STREAM' AS object_type, 'none visible' AS object_subtype, 0 AS object_count, 0 AS database_count,
         'SHOW STREAMS' AS source, 'streams_not_visible_or_none' AS reason
  FROM n_streams WHERE n = 0
  UNION ALL
  SELECT 'TASK', 'none visible', 0, 0, 'SHOW TASKS', 'tasks_not_visible'
  FROM n_tasks CROSS JOIN task_runs WHERE n_tasks.n = 0 AND task_runs.n > 0
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       object_type, object_subtype, object_count, database_count, source,
       reason AS not_assessed_reason,
       IFF(reason IS NULL, 'OK', 'NOT_ASSESSED') AS status
FROM (SELECT * FROM agg UNION ALL SELECT * FROM gaps)
ORDER BY object_type, object_count DESC
