-- query_id: sf_use_last_active
-- title: When each table and object was last active
-- domain: governance_access   tier: standard
-- entity: objects = object_key
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES, SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES, SNOWFLAKE.ACCOUNT_USAGE.VIEWS,
--   SNOWFLAKE.ACCOUNT_USAGE.STAGES, SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS, SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES,
--   SNOWFLAKE.ACCOUNT_USAGE.PIPES, SNOWFLAKE.ACCOUNT_USAGE.TASKS, SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (or GOVERNANCE_VIEWER, OBJECT_VIEWER and
--   USAGE_VIEWER); Enterprise edition
-- params: :lookback_days (default 365) days of history it looks back, which is all ACCESS_HISTORY keeps;
--   :top_n (default 2000) objects: kept per kind and band, largest tables and oldest other objects; the band totals are exact
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a busy account.
-- read_this: one row = one live table or object (row_level = 'object'), or one kind, band, database and
--   schema as a total row (row_level = 'band', exact, with objects and storage_gb). last_read_at, last_write_at and
--   last_run_at look back up to 365 days; NULL means none in that history. last_active_at is the newest of
--   read, write, run, DDL, last change and creation, so a new table reads as active. active_band is the
--   time since: under_30, d30_90, d90_180, d180_360, over_360. beyond_history = nothing in the history
--   the account has, and it is too short to say how long (history_days). use_pattern for tables:
--   read_and_written, read_not_written, written_not_read, no_read_no_write; for other objects: used or
--   not_used. last_write_at comes from ACCESS_HISTORY and TABLE_DML_HISTORY only. dependents = live objects
--   built on it, from OBJECT_DEPENDENCIES; NULL for procedures, tasks and pipes, which it can't tell. Sizes are not priced here:
--   what an unread table costs is on sf_storage_unused_tables.
-- healthy: status = OK; this check only shows use and never flags. Priced unused tables are in
--   sf_storage_unused_tables, and the 90-day figure there is the one that reaches Waste & savings.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows (the role cannot see it, or an undetected
--   Standard edition); task and pipe rows still read then, from their own history. On a detected Standard
--   account the export skips the whole check.
-- actions: 1) start from the oldest band and the largest tables (free); 2) check dependents and ask the
--   owner: reads through shares, streams and intermediate views are not recorded (free); 3) rename or
--   revoke access for a grace period, then drop (config).
-- next: sf_storage_unused_tables
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows (Standard edition, or the role cannot
--   see it), so reads and writes cannot be dated
-- caveats: No activity does not prove nothing uses an object. ACCESS_HISTORY leaves out reads by data sharing
--   consumers and replication, stream updates, failed queries, intermediate views (only the top view and the
--   base table are recorded) and nested functions. It lags up to 3 hours and keeps 365 days. last_altered also
--   moves on DDL and background maintenance, so an unused table can read as more recent than it is, never
--   older, while still reading as no write. A load neither write source records also reads as no write.
--   External and hybrid tables are not in TABLE_STORAGE_METRICS, so they have no row. Streams, sequences and
--   file formats have no inventory view, so an unused one cannot be listed. STAGES, PIPES, FUNCTIONS and
--   PROCEDURES show only what the role can see. Procedure overloads are merged and have no id, so no
--   dependents. Scans a year of ACCESS_HISTORY once, so on a busy account it can reach the statement time limit.
--   The FLATTENs are not OUTER: a query with no such objects adds no event, which is intended.
WITH -- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
-- settings. The YES/NO text flags are turned into booleans so every storage check reads them alike.
sf_storage_live_tables AS (
  SELECT m.id AS table_id, m.table_catalog AS database_name, m.table_catalog_id AS database_id,
         m.table_schema AS schema_name, m.table_schema_id AS schema_id, m.table_name,
         m.table_catalog || '.' || m.table_schema || '.' || m.table_name AS table_fqn,
         m.clone_group_id,
         COALESCE(m.active_bytes, 0) AS active_bytes,
         COALESCE(m.time_travel_bytes, 0) AS time_travel_bytes,
         COALESCE(m.failsafe_bytes, 0) AS failsafe_bytes,
         COALESCE(m.retained_for_clone_bytes, 0) AS retained_for_clone_bytes,
         COALESCE(m.active_bytes, 0) + COALESCE(m.time_travel_bytes, 0) + COALESCE(m.failsafe_bytes, 0)
           + COALESCE(m.retained_for_clone_bytes, 0) AS total_bytes,
         -- no TABLES row would make this NULL and drop the table from NOT is_transient filters
         COALESCE(m.is_transient = 'YES' OR t.is_transient = 'YES', m.is_transient = 'YES', FALSE) AS is_transient,
         COALESCE(t.table_type, 'BASE TABLE') AS table_type,
         t.retention_time, t.clustering_key,
         COALESCE(t.auto_clustering_on = 'YES', FALSE) AS auto_clustering_on,
         COALESCE(t.is_iceberg = 'YES', FALSE) AS is_iceberg,
         COALESCE(t.is_dynamic = 'YES', FALSE) AS is_dynamic,
         COALESCE(t.is_hybrid = 'YES', FALSE) AS is_hybrid,
         t.row_count, t.bytes AS table_bytes, t.table_owner, t.created, t.last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS m
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TABLES t ON t.table_id = m.id AND t.deleted IS NULL
  -- Fail-safe rows have NULL names (and can carry deleted = FALSE): they are not live tables.
  WHERE NOT COALESCE(m.deleted, FALSE) AND m.table_dropped IS NULL
    AND m.schema_dropped IS NULL AND m.catalog_dropped IS NULL
    AND m.table_name IS NOT NULL AND m.table_entered_failsafe IS NULL
),
-- Live views, stages, functions, procedures, pipes and tasks, one row per object, outside the SNOWFLAKE
-- database. inv has object_key: the id, or the name for a procedure, whose overloads merge into one row.
-- inv_fqn maps a name to its key, for events without an object id.
inv0 AS (
  SELECT 'VIEW' AS object_domain, IFF(is_secure = 'YES', 'secure', CAST(NULL AS VARCHAR)) AS object_subtype,
         table_catalog AS database_name, table_schema AS schema_name, table_name AS object_name,
         TO_VARCHAR(table_id) AS object_id, table_owner AS object_owner, created, last_ddl AS last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.VIEWS
  WHERE deleted IS NULL AND table_catalog <> 'SNOWFLAKE'
  UNION ALL
  SELECT 'STAGE', stage_type, stage_catalog, stage_schema, stage_name, TO_VARCHAR(stage_id), stage_owner,
         created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.STAGES
  WHERE deleted IS NULL AND stage_catalog <> 'SNOWFLAKE'
  UNION ALL
  SELECT 'FUNCTION', function_language, function_catalog, function_schema, function_name,
         TO_VARCHAR(function_id), function_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.FUNCTIONS
  WHERE deleted IS NULL AND function_catalog <> 'SNOWFLAKE'
  UNION ALL
  -- no id: one row per name, overloads merged
  SELECT 'PROCEDURE', MAX(procedure_language), procedure_catalog, procedure_schema, procedure_name,
         CAST(NULL AS VARCHAR), MAX(procedure_owner), MIN(created), MAX(last_altered)
  FROM SNOWFLAKE.ACCOUNT_USAGE.PROCEDURES
  WHERE deleted IS NULL AND procedure_catalog <> 'SNOWFLAKE'
  GROUP BY procedure_catalog, procedure_schema, procedure_name
  UNION ALL
  SELECT 'PIPE', CAST(NULL AS VARCHAR), pipe_catalog, pipe_schema, pipe_name, TO_VARCHAR(pipe_id),
         pipe_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPES
  WHERE deleted IS NULL AND pipe_catalog <> 'SNOWFLAKE'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY pipe_id ORDER BY last_altered DESC) = 1
  UNION ALL
  SELECT 'TASK', state, task_database, task_schema, task_name, TO_VARCHAR(id), task_owner, created, last_altered
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASKS
  WHERE deleted IS NULL AND task_database <> 'SNOWFLAKE'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY last_altered DESC) = 1
),
inv AS (
  SELECT object_domain, object_subtype, database_name, schema_name, object_name, object_id, object_owner,
         created, last_altered,
         UPPER(database_name || '.' || schema_name || '.' || object_name) AS object_fqn,
         IFF(object_domain = 'PROCEDURE', UPPER(database_name || '.' || schema_name || '.' || object_name),
             object_id) AS object_key
  FROM inv0
),
inv_fqn AS (
  -- name fallback for events without an object id; overloads share a name, so one key per name
  SELECT object_domain, object_fqn, MIN(object_key) AS object_key
  FROM inv
  GROUP BY 1, 2
),
ah AS (
  SELECT query_id, query_start_time, base_objects_accessed, direct_objects_accessed, objects_modified,
         object_modified_by_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND query_start_time < __AS_OF_DATE__
),
seen AS (
  SELECT COUNT(*) AS access_rows, COALESCE(DATEDIFF(day, MIN(query_start_time), __AS_OF_DATE__), 0) AS history_days
  FROM ah
),
writes_raw AS (
  SELECT a.query_id, a.query_start_time, 'write' AS kind, UPPER(f.value:"objectDomain"::STRING) AS object_domain,
         f.value:"objectId"::NUMBER AS object_id, UPPER(f.value:"objectName"::STRING) AS object_name
  FROM ah a, LATERAL FLATTEN(input => a.objects_modified) f
),
reads_raw AS (
  SELECT a.query_id, a.query_start_time, 'read' AS kind, UPPER(f.value:"objectDomain"::STRING) AS object_domain,
         f.value:"objectId"::NUMBER AS object_id, UPPER(f.value:"objectName"::STRING) AS object_name
  FROM ah a, LATERAL FLATTEN(input => a.base_objects_accessed) f
  UNION ALL
  SELECT a.query_id, a.query_start_time, 'read', UPPER(f.value:"objectDomain"::STRING),
         f.value:"objectId"::NUMBER, UPPER(f.value:"objectName"::STRING)
  FROM ah a, LATERAL FLATTEN(input => a.direct_objects_accessed) f
  -- table-like objects are already in base_objects_accessed; views, stages and functions are not
  WHERE UPPER(f.value:"objectDomain"::STRING) NOT IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE',
                                                       'EXTERNAL TABLE', 'MATERIALIZED VIEW')
),
reads AS (
  -- a MERGE or INSERT ... SELECT from itself is a write, not a read of its target
  SELECT r.query_id, r.query_start_time, r.kind, r.object_domain, r.object_id, r.object_name
  FROM reads_raw r
  LEFT JOIN writes_raw w ON w.query_id = r.query_id AND w.object_id = r.object_id AND w.object_domain = r.object_domain
  WHERE w.query_id IS NULL
),
ev AS (
  SELECT query_start_time, kind, object_domain, object_id, object_name FROM reads
  UNION ALL
  SELECT query_start_time, kind, object_domain, object_id, object_name FROM writes_raw
  UNION ALL
  SELECT a.query_start_time, 'ddl', UPPER(COALESCE(a.object_modified_by_ddl:"objectDomain"::STRING, 'UNKNOWN')),
         a.object_modified_by_ddl:"objectId"::NUMBER, UPPER(a.object_modified_by_ddl:"objectName"::STRING)
  FROM ah a
  WHERE a.object_modified_by_ddl IS NOT NULL
),
table_ev AS (
  SELECT object_id AS table_id,
         MAX(IFF(kind = 'read', query_start_time, NULL)) AS last_read_at,
         MAX(IFF(kind = 'write', query_start_time, NULL)) AS last_write_at,
         MAX(IFF(kind = 'ddl', query_start_time, NULL)) AS last_ddl_at
  FROM ev
  WHERE object_domain IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  GROUP BY 1
),
dml AS (
  SELECT table_id, MAX(start_time) AS last_dml_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
tx AS (
  SELECT table_id, last_ddl
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY table_id ORDER BY last_altered DESC) = 1
),
deps AS (
  SELECT referenced_object_id AS object_id, UPPER(referenced_object_domain) AS object_domain,
         COUNT(DISTINCT referencing_object_id) AS dependents
  FROM SNOWFLAKE.ACCOUNT_USAGE.OBJECT_DEPENDENCIES
  GROUP BY 1, 2
),
table_deps AS (
  SELECT object_id, SUM(dependents) AS dependents
  FROM deps
  WHERE object_domain IN ('TABLE', 'DYNAMIC TABLE', 'ICEBERG TABLE', 'EXTERNAL TABLE', 'MATERIALIZED VIEW')
  GROUP BY 1
),
object_ev AS (
  SELECT IFF(e.object_domain = 'SECURE VIEW', 'VIEW', e.object_domain) AS object_domain,
         IFF(e.object_domain = 'PROCEDURE', UPPER(REGEXP_REPLACE(e.object_name, '[(].*$', '')),
             COALESCE(TO_VARCHAR(e.object_id), f.object_key)) AS object_key,
         MAX(IFF(e.kind = 'read', e.query_start_time, NULL)) AS last_read_at,
         MAX(IFF(e.kind = 'write', e.query_start_time, NULL)) AS last_write_at,
         MAX(IFF(e.kind = 'ddl', e.query_start_time, NULL)) AS last_ddl_at
  FROM ev e
  LEFT JOIN inv_fqn f ON f.object_domain = IFF(e.object_domain = 'SECURE VIEW', 'VIEW', e.object_domain)
                     AND f.object_fqn = UPPER(REGEXP_REPLACE(e.object_name, '[(].*$', ''))
  WHERE e.object_domain IN ('VIEW', 'SECURE VIEW', 'STAGE', 'FUNCTION', 'PROCEDURE', 'PIPE', 'TASK')
  GROUP BY 1, 2
),
runs AS (
  SELECT 'TASK' AS object_domain, i.object_key, MAX(th.scheduled_time) AS last_run_at
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY th
  JOIN inv i ON i.object_domain = 'TASK'
            AND i.object_fqn = UPPER(th.database_name || '.' || th.schema_name || '.' || th.name)
  WHERE th.scheduled_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND th.scheduled_time < __AS_OF_DATE__
    AND th.state IN ('SUCCEEDED', 'FAILED')
  GROUP BY 1, 2
  UNION ALL
  SELECT 'PIPE', TO_VARCHAR(pipe_id), MAX(start_time)
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND pipe_id IS NOT NULL
  GROUP BY 1, 2
),
u AS (
  SELECT 'TABLE' AS object_kind, lt.table_type AS object_subtype, lt.database_name, lt.schema_name,
         lt.table_name AS object_name, TO_VARCHAR(lt.table_id) AS object_id, TO_VARCHAR(lt.table_id) AS raw_key,
         lt.table_fqn AS object_fqn, lt.table_owner AS object_owner, lt.created, lt.last_altered,
         e.last_read_at,
         -- never last_altered, which also moves on DDL and maintenance; DML history includes Snowpipe
         NULLIF(GREATEST(COALESCE(e.last_write_at, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(d.last_dml_at, '1970-01-01'::TIMESTAMP_LTZ)), '1970-01-01'::TIMESTAMP_LTZ) AS last_write_at,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_run_at,
         NULLIF(GREATEST(COALESCE(e.last_ddl_at, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(x.last_ddl, '1970-01-01'::TIMESTAMP_LTZ)), '1970-01-01'::TIMESTAMP_LTZ) AS last_ddl_at,
         COALESCE(td.dependents, 0) AS dependents, lt.total_bytes / POWER(1024, 3) AS storage_gb
  FROM sf_storage_live_tables lt
  LEFT JOIN table_ev e ON e.table_id = lt.table_id
  LEFT JOIN dml d ON d.table_id = lt.table_id
  LEFT JOIN tx x ON x.table_id = lt.table_id
  LEFT JOIN table_deps td ON td.object_id = lt.table_id
  WHERE lt.database_name <> 'SNOWFLAKE'
  UNION ALL
  SELECT i.object_domain, i.object_subtype, i.database_name, i.schema_name, i.object_name, i.object_id, i.object_key,
         i.object_fqn, i.object_owner, i.created, i.last_altered, e.last_read_at, e.last_write_at, r.last_run_at,
         e.last_ddl_at,
         -- a procedure has no id to join on, and the view doesn't cover tasks or pipes: unknown, not zero
         IFF(i.object_id IS NULL OR i.object_domain IN ('TASK', 'PIPE'), CAST(NULL AS NUMBER), COALESCE(dp.dependents, 0)),
         CAST(NULL AS DOUBLE)
  FROM inv i
  LEFT JOIN object_ev e ON e.object_domain = i.object_domain AND e.object_key = i.object_key
  LEFT JOIN runs r ON r.object_domain = i.object_domain AND r.object_key = i.object_key
  LEFT JOIN deps dp ON TO_VARCHAR(dp.object_id) = i.object_id AND dp.object_domain = i.object_domain
),
d1 AS (
  SELECT u.*,
         -- tasks and pipes date from their own history, which keeps the full 365 days
         IFF(u.object_kind IN ('TASK', 'PIPE'), :lookback_days, s.history_days) AS history_days,
         s.access_rows > 0 OR u.object_kind IN ('TASK', 'PIPE') AS assessed,
         NULLIF(GREATEST(COALESCE(u.last_read_at, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(u.last_write_at, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(u.last_run_at, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(u.last_ddl_at, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(u.last_altered, '1970-01-01'::TIMESTAMP_LTZ),
                         COALESCE(u.created, '1970-01-01'::TIMESTAMP_LTZ)), '1970-01-01'::TIMESTAMP_LTZ) AS last_active_at
  FROM u CROSS JOIN seen s
),
d2 AS (
  -- from the last day the export covers (as-of is the first one left out); object views have no cut-off, so never below 0
  SELECT d1.*, IFF(last_active_at IS NULL, CAST(NULL AS NUMBER),
                   GREATEST(0, DATEDIFF(day, last_active_at, DATEADD(day, -1, __AS_OF_DATE__)))) AS days_since_active
  FROM d1
),
b AS (
  SELECT d2.*,
         CASE
           WHEN NOT assessed THEN 'not_assessed'
           WHEN days_since_active < 30 THEN 'under_30'
           -- older than the history the account has: nothing seen, but no way to say since when
           WHEN (days_since_active IS NULL OR days_since_active > history_days) AND history_days < 360 THEN 'beyond_history'
           WHEN days_since_active IS NULL OR days_since_active >= 360 THEN 'over_360'
           WHEN days_since_active < 90 THEN 'd30_90'
           WHEN days_since_active < 180 THEN 'd90_180'
           ELSE 'd180_360'
         END AS active_band,
         CASE
           WHEN NOT assessed THEN CAST(NULL AS VARCHAR)
           WHEN object_kind <> 'TABLE' THEN IFF(COALESCE(last_read_at, last_write_at, last_run_at) IS NULL, 'not_used', 'used')
           WHEN last_read_at IS NOT NULL AND last_write_at IS NOT NULL THEN 'read_and_written'
           WHEN last_read_at IS NOT NULL THEN 'read_not_written'
           WHEN last_write_at IS NOT NULL THEN 'written_not_read'
           ELSE 'no_read_no_write'
         END AS use_pattern
  FROM d2
),
r AS (
  SELECT b.*, ROW_NUMBER() OVER (PARTITION BY object_kind, active_band
                                 ORDER BY storage_gb DESC NULLS LAST, last_active_at NULLS FIRST, raw_key) AS band_rank
  FROM b
),
totals AS (
  -- by database and schema, so the page's filters narrow the bars with the lists
  SELECT object_kind, active_band, database_name, schema_name, history_days, assessed,
         COUNT(*) AS objects, SUM(storage_gb) AS storage_gb
  FROM b
  GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, 'object' AS row_level, FALSE AS is_total_row,
       r.object_kind, r.object_subtype, r.database_name, r.schema_name, r.object_name, r.object_id,
       r.object_kind || ':' || r.raw_key AS object_key, r.object_fqn, r.object_owner, r.created, r.last_altered,
       r.last_read_at, r.last_write_at, r.last_run_at, r.last_ddl_at, r.last_active_at, r.days_since_active,
       r.active_band, r.use_pattern, r.dependents, r.storage_gb,
       CAST(NULL AS NUMBER) AS objects, r.history_days,
       IFF(r.assessed, CAST(NULL AS VARCHAR), 'no_access_history') AS not_assessed_reason,
       IFF(r.assessed, 'OK', 'NOT_ASSESSED') AS status
FROM r
WHERE r.band_rank <= :top_n
UNION ALL
SELECT 0, __ACCOUNT_ID__, 'band', TRUE, t.object_kind, CAST(NULL AS VARCHAR), t.database_name,
       t.schema_name, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       t.object_kind || ':' || t.active_band || ':' || COALESCE(t.database_name, '') || '.' || COALESCE(t.schema_name, ''),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ),
       CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS TIMESTAMP_LTZ),
       CAST(NULL AS TIMESTAMP_LTZ), CAST(NULL AS NUMBER), t.active_band, CAST(NULL AS VARCHAR),
       CAST(NULL AS NUMBER), t.storage_gb, t.objects, t.history_days,
       IFF(t.assessed, CAST(NULL AS VARCHAR), 'no_access_history'),
       IFF(t.assessed, 'OK', 'NOT_ASSESSED')
FROM totals t
ORDER BY is_total_row DESC, object_kind, last_active_at NULLS FIRST
