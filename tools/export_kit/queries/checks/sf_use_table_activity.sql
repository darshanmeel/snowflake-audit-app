-- query_id: sf_use_table_activity
-- title: How each table is used: active, cooling, written but never read, idle
-- domain: storage   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES, SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 1000) rows: table rows kept per ranking (most active, largest unread)
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one live table (row_level = 'table') or one usage class (row_level = 'class').
--   Class rows are total rows with uncapped totals of tables, storage_gb, active_gb and dml_rows (queries and readers are
--   NULL there: distinct counts cannot be summed). usage_class: active = read in the newer half of the
--   window; cooling = read only in the older half; written_never_read = written (ACCESS_HISTORY or
--   TABLE_DML_HISTORY) but not read; new = created inside the window and not used yet; idle = nothing in
--   the window. read/write/ddl_queries are distinct queries from ACCESS_HISTORY (reads also through views);
--   dml_rows = rows added + removed + updated. activity_rank orders tables with any use by total queries (1 = busiest, NULL = no use);
--   size_rank orders the tables that are not active or cooling by bytes (1 = largest). Table rows are
--   capped to activity_rank <= top_n or size_rank <= top_n; class rows always cover every live table.
--   last_ddl / last_ddl_user_name come from TABLES (LAST_DDL, LAST_DDL_BY). storage_gb counts active,
--   Time Travel, Fail-safe and clone-retained bytes; active_gb only active bytes.
-- healthy: status = OK whenever ACCESS_HISTORY has rows; this check describes use and never flags.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY is empty (Standard edition or no activity). Flagging
--   and dollars live in sf_storage_unused_tables, sf_storage_churn_unread and sf_use_unused_clones.
-- actions: 1) start from written_never_read and idle tables with high storage_gb and run
--   sf_storage_unused_tables for the cost (free); 2) ask the owner before dropping (free).
-- next: sf_storage_unused_tables
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so reads, writes and DDL cannot be counted
-- caveats: ACCESS_HISTORY needs Enterprise edition and lags up to 3 hours. External and hybrid tables
--   are not in TABLE_STORAGE_METRICS so they have no row. Reads by data-sharing consumers, replication
--   and streams are not in ACCESS_HISTORY. TABLE_DML_HISTORY lags up to 6 hours and skips hybrid tables
--   and background DML, so the last hours can read written_never_read or understate dml_rows. A live table
--   with no TABLES row has NULL created and last_ddl and falls to idle, never new. The include's
--   direct_objects_accessed branch is not OUTER: queries with no such objects add no event, which is intended. last_altered also moves on maintenance such as clustering.
WITH -- ACCESS_HISTORY flattened to one event per query x object x kind (read, write, ddl). Columns: query_id,
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
),
-- Live tables with their current storage split: TABLE_STORAGE_METRICS holds the bytes, TABLES the
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
seen AS (
  SELECT access_rows FROM sf_use_access_seen
),
a AS (
  SELECT object_id AS table_id,
         COUNT(DISTINCT IFF(kind = 'read', query_id, NULL)) AS read_queries,
         COUNT(DISTINCT IFF(kind = 'write', query_id, NULL)) AS write_queries,
         COUNT(DISTINCT IFF(kind = 'ddl', query_id, NULL)) AS ddl_queries,
         COUNT(DISTINCT IFF(kind = 'read', user_name, NULL)) AS readers,
         COUNT(DISTINCT IFF(kind = 'write', user_name, NULL)) AS writers,
         MAX(IFF(kind = 'read', query_start_time, NULL)) AS last_read_at,
         MAX(IFF(kind = 'write', query_start_time, NULL)) AS last_write_at,
         MAX(IFF(kind = 'ddl', query_start_time, NULL)) AS last_ddl_at,
         COUNT(DISTINCT usage_date) AS active_days
  FROM sf_use_access_events
  WHERE is_table_like
  GROUP BY object_id
),
dml AS (
  SELECT table_id,
         SUM(COALESCE(rows_added, 0) + COALESCE(rows_removed, 0) + COALESCE(rows_updated, 0)) AS dml_rows
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY table_id
),
tx AS (
  SELECT table_id, last_ddl, last_ddl_by
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES
  WHERE deleted IS NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY table_id ORDER BY last_altered DESC) = 1
),
j AS (
  SELECT lt.*, tx.last_ddl, tx.last_ddl_by AS last_ddl_user_name,
         COALESCE(a.read_queries, 0) AS read_queries, COALESCE(a.write_queries, 0) AS write_queries,
         COALESCE(a.ddl_queries, 0) AS ddl_queries, COALESCE(a.readers, 0) AS readers,
         COALESCE(a.writers, 0) AS writers, COALESCE(dml.dml_rows, 0) AS dml_rows,
         COALESCE(a.active_days, 0) AS active_days, a.last_read_at, a.last_write_at, a.last_ddl_at
  FROM sf_storage_live_tables lt
  LEFT JOIN a ON a.table_id = lt.table_id
  LEFT JOIN dml ON dml.table_id = lt.table_id
  LEFT JOIN tx ON tx.table_id = lt.table_id
  WHERE lt.database_name <> 'SNOWFLAKE'
),
t AS (
  SELECT j.*,
         CASE
           WHEN last_read_at >= DATEADD(day, -CEIL(:period_days / 2), __AS_OF_DATE__) THEN 'active'
           -- read only in the older half of the window, so it works for any period_days
           WHEN read_queries > 0 THEN 'cooling'
           WHEN write_queries > 0 OR dml_rows > 0 THEN 'written_never_read'
           -- too young to call idle
           WHEN created >= DATEADD(day, -:period_days, __AS_OF_DATE__) THEN 'new'
           ELSE 'idle'
         END AS usage_class
  FROM j
),
r AS (
  SELECT t.*,
         IFF(read_queries + write_queries + ddl_queries + dml_rows = 0, NULL,
             ROW_NUMBER() OVER (ORDER BY read_queries + write_queries + ddl_queries DESC, dml_rows DESC,
                                         total_bytes DESC, table_fqn)) AS activity_rank,
         IFF(usage_class IN ('active', 'cooling'), NULL,
             ROW_NUMBER() OVER (PARTITION BY usage_class IN ('active', 'cooling') ORDER BY total_bytes DESC))
           AS size_rank
  FROM t
),
rows_t AS (
  SELECT 'table' AS row_level, FALSE AS is_total_row, usage_class, database_name, database_id, schema_name,
         table_name, table_id, table_fqn, UPPER(table_fqn) AS lineage_fqn, table_type, is_transient,
         is_dynamic, is_iceberg, table_owner, created, last_altered, last_ddl, last_ddl_user_name, row_count,
         1 AS tables, total_bytes / POWER(1024, 3) AS storage_gb, active_bytes / POWER(1024, 3) AS active_gb,
         read_queries, write_queries, ddl_queries, readers, writers, dml_rows, active_days, last_read_at,
         last_write_at, last_ddl_at, activity_rank, size_rank
  FROM r
  WHERE activity_rank <= :top_n OR size_rank <= :top_n
),
rows_c AS (
  SELECT 'class' AS row_level, TRUE AS is_total_row, c.usage_class AS usage_class, CAST(NULL AS VARCHAR) AS database_name,
         CAST(NULL AS NUMBER) AS database_id, CAST(NULL AS VARCHAR) AS schema_name,
         CAST(NULL AS VARCHAR) AS table_name, CAST(NULL AS NUMBER) AS table_id,
         CAST(NULL AS VARCHAR) AS table_fqn, CAST(NULL AS VARCHAR) AS lineage_fqn,
         CAST(NULL AS VARCHAR) AS table_type, CAST(NULL AS BOOLEAN) AS is_transient,
         CAST(NULL AS BOOLEAN) AS is_dynamic, CAST(NULL AS BOOLEAN) AS is_iceberg,
         CAST(NULL AS VARCHAR) AS table_owner, CAST(NULL AS TIMESTAMP_LTZ) AS created,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_altered, CAST(NULL AS TIMESTAMP_LTZ) AS last_ddl,
         CAST(NULL AS VARCHAR) AS last_ddl_user_name, CAST(NULL AS NUMBER) AS row_count,
         COALESCE(g.tables, 0) AS tables, COALESCE(g.storage_gb, 0) AS storage_gb,
         COALESCE(g.active_gb, 0) AS active_gb,
         CAST(NULL AS NUMBER) AS read_queries, CAST(NULL AS NUMBER) AS write_queries,
         CAST(NULL AS NUMBER) AS ddl_queries, CAST(NULL AS NUMBER) AS readers, CAST(NULL AS NUMBER) AS writers,
         COALESCE(g.dml_rows, 0) AS dml_rows, CAST(NULL AS NUMBER) AS active_days,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_read_at, CAST(NULL AS TIMESTAMP_LTZ) AS last_write_at,
         CAST(NULL AS TIMESTAMP_LTZ) AS last_ddl_at, CAST(NULL AS NUMBER) AS activity_rank,
         CAST(NULL AS NUMBER) AS size_rank
  FROM (VALUES ('active'), ('cooling'), ('written_never_read'), ('new'), ('idle')) c(usage_class)
  LEFT JOIN (
    SELECT usage_class, COUNT(*) AS tables, SUM(total_bytes) / POWER(1024, 3) AS storage_gb,
           SUM(active_bytes) / POWER(1024, 3) AS active_gb, SUM(dml_rows) AS dml_rows
    FROM r
    GROUP BY usage_class
  ) g ON g.usage_class = c.usage_class
),
u AS (
  SELECT * FROM rows_t
  UNION ALL
  SELECT * FROM rows_c
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, u.*,
       CASE WHEN s.access_rows = 0 THEN 'no_access_history' END AS not_assessed_reason,
       IFF(s.access_rows = 0, 'NOT_ASSESSED', 'OK') AS status
FROM seen s LEFT JOIN u ON TRUE
ORDER BY is_total_row DESC, activity_rank, storage_gb DESC
