-- query_id: sf_acct_object_counts
-- title: Inventory of account objects by type
-- domain: governance_access   tier: standard
-- entity: object types = object_type, object_subtype
-- windowed: no
-- pre: SHOW STREAMS IN ACCOUNT
-- pre: SHOW TASKS IN ACCOUNT
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DATABASES, SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES, SNOWFLAKE.ACCOUNT_USAGE.STAGES, SNOWFLAKE.ACCOUNT_USAGE.PIPES,
--   SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS, SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES,
--   SNOWFLAKE.ACCOUNT_USAGE.SEQUENCES, SNOWFLAKE.ACCOUNT_USAGE.FILE_FORMATS,
--   SNOWFLAKE.ACCOUNT_USAGE.USERS, SNOWFLAKE.ACCOUNT_USAGE.ROLES, SHOW STREAMS IN ACCOUNT, SHOW TASKS
--   IN ACCOUNT, SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; a role that can see the objects SHOW lists
--   (SHOW returns only those); MONITOR on the tasks (SHOW lists only tasks the role can see)
-- params: none
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one object type (and subtype: table kind, stage kind, language, task state) with
--   how many live objects exist and in how many databases. It tells the reader what the account uses,
--   so empty tabs for unused features (no streams, no Iceberg tables) read as "not used" rather than
--   "not checked". source says where the count comes from.
-- healthy: status = OK; this is an inventory for the Coverage tab. A SHOW that lists nothing reads
--   NOT_ASSESSED (streams: none visible or none exist; tasks: task runs exist but SHOW lists none).
-- investigate_if: never WARN; compare counts with what the platform team expects.
-- actions: 1) look for surprises: many transient or temporary tables, external stages, JavaScript
--   functions, suspended tasks (free); 2) follow the matching check for any feature in use (free).
-- next: none
-- caveats: ACCOUNT_USAGE views lag up to 3 hours and omit the SNOWFLAKE database and shared (imported)
--   databases' contents; SHOW counts only what the export role can see and at most 10,000 rows each.
WITH inv AS (
  SELECT 'DATABASE' AS object_type, IFF(is_transient = 'YES', 'TRANSIENT', 'PERMANENT') AS object_subtype, database_name AS db,
         'ACCOUNT_USAGE.DATABASES' AS source
  FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASES WHERE deleted IS NULL
  UNION ALL
  SELECT 'SCHEMA', IFF(is_transient = 'YES', 'TRANSIENT', 'PERMANENT'), catalog_name, 'ACCOUNT_USAGE.SCHEMATA'
  FROM SNOWFLAKE.ACCOUNT_USAGE.SCHEMATA WHERE deleted IS NULL AND schema_name <> 'INFORMATION_SCHEMA'
  UNION ALL
  SELECT IFF(table_type LIKE '%VIEW%', 'VIEW', 'TABLE'),
         CASE WHEN is_iceberg = 'YES' THEN 'ICEBERG TABLE'
              WHEN is_dynamic = 'YES' THEN 'DYNAMIC TABLE'
              WHEN is_hybrid = 'YES' THEN 'HYBRID TABLE'
              WHEN table_type = 'BASE TABLE' AND is_transient = 'YES' THEN 'TRANSIENT TABLE'
              ELSE table_type END,
         table_catalog, 'ACCOUNT_USAGE.TABLES'
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES WHERE deleted IS NULL AND table_schema <> 'INFORMATION_SCHEMA'
  UNION ALL
  SELECT 'STAGE', COALESCE(stage_type, 'UNKNOWN'), stage_catalog, 'ACCOUNT_USAGE.STAGES'
  FROM SNOWFLAKE.ACCOUNT_USAGE.STAGES WHERE deleted IS NULL
  UNION ALL
  SELECT 'PIPE', IFF(is_autoingest_enabled = 'YES', 'AUTO_INGEST', 'REST / MANUAL'), pipe_catalog, 'ACCOUNT_USAGE.PIPES'
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES WHERE deleted IS NULL
  UNION ALL
  SELECT 'FUNCTION', UPPER(function_language), function_catalog, 'ACCOUNT_USAGE.FUNCTIONS'
  FROM SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS WHERE deleted IS NULL
  UNION ALL
  SELECT 'PROCEDURE', UPPER(procedure_language), procedure_catalog, 'ACCOUNT_USAGE.PROCEDURES'
  FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES WHERE deleted IS NULL
  UNION ALL
  SELECT 'SEQUENCE', 'SEQUENCE', sequence_catalog, 'ACCOUNT_USAGE.SEQUENCES'
  FROM SNOWFLAKE.ACCOUNT_USAGE.SEQUENCES WHERE deleted IS NULL
  UNION ALL
  SELECT 'FILE FORMAT', UPPER(file_format_type), file_format_catalog, 'ACCOUNT_USAGE.FILE_FORMATS'
  FROM SNOWFLAKE.ACCOUNT_USAGE.FILE_FORMATS WHERE deleted IS NULL
  UNION ALL
  SELECT 'USER', COALESCE(UPPER(type), 'PERSON')
                 || IFF(COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE), ' (disabled)', ''),
         CAST(NULL AS VARCHAR), 'ACCOUNT_USAGE.USERS'
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS WHERE deleted_on IS NULL
  UNION ALL
  SELECT 'ROLE', 'ROLE', CAST(NULL AS VARCHAR), 'ACCOUNT_USAGE.ROLES'
  FROM SNOWFLAKE.ACCOUNT_USAGE.ROLES WHERE deleted_on IS NULL
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
  SELECT COUNT(*) AS n FROM (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY LIMIT 1)
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
