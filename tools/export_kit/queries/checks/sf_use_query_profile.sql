-- query_id: sf_use_query_profile
-- title: How the queries on each busy table and of each busy user run: count, time, scan and spill
-- domain: performance   tier: standard
-- entity: tables and users = row_level, table_fqn, user_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS, SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 25) tables and users: only the busiest of each by queries are listed;
--   :top_pairs (default 10) users kept per table and tables kept per user
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one table, one user, or one pair of them; row_level says which. Tables and users
--   are the :top_n busiest of each; table_user is the :top_pairs busiest users of a table and user_table
--   the same the other way round. queries counts distinct
--   queries that read or wrote the table (or that the user ran on tables); the time, scan and spill
--   figures are those queries' own, from QUERY_HISTORY: avg_elapsed_s and p90_elapsed_s are seconds per
--   query, avg_partitions_scanned is micro-partitions per query and scan_pct the share of the partitions
--   they could have read, spill_pct the share of queries that spilled. timed_queries counts the queries
--   found in QUERY_HISTORY; the figures cover those. entity_rank 1 = most queries; pair_rank orders the
--   pairs inside their table or user.
-- healthy: status = OK on every listed row; this check describes how queries run, it does not judge them.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows in the window.
-- actions: 1) open the table's or user's top query shapes (sf_use_top_query_shapes) when the average time,
--   scan share or spill is high (free); 2) cluster a large table that most queries scan in full, or give
--   the spilling shapes a larger warehouse (config).
-- next: sf_use_top_query_shapes
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so which queries used a table cannot be told
-- caveats: a query's time, scan and spill are the whole query's, not the share spent on one table, so a
--   query that joins three tables counts in full for each. Partition counts are for the whole query too.
--   Reads through views count for the base tables. ACCESS_HISTORY lags up to 3 hours and records
--   successful queries only, so failed queries are not here. Reads by data-sharing consumers are not in it.
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
-- One row per query in ACCESS_HISTORY's window with how it ran, from QUERY_HISTORY: shape (parameterized
-- hash), type, warehouse, seconds, partitions, bytes scanned and spilled. Needs sf_use_ah. Never query text.
sf_use_query_metrics AS (
  SELECT q.query_id, MAX(q.query_parameterized_hash) AS shape_hash, MAX(UPPER(q.query_type)) AS query_type,
         MAX(UPPER(q.warehouse_name)) AS warehouse_name,
         MAX(q.total_elapsed_time) / 1000 AS elapsed_s,
         MAX(q.partitions_scanned) AS partitions_scanned, MAX(q.partitions_total) AS partitions_total,
         MAX(q.bytes_scanned) AS bytes_scanned,
         MAX(COALESCE(q.bytes_spilled_to_local_storage, 0) + COALESCE(q.bytes_spilled_to_remote_storage, 0)) AS bytes_spilled,
         MAX(COALESCE(q.bytes_spilled_to_remote_storage, 0)) AS bytes_spilled_remote
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  WHERE q.start_time >= DATEADD(day, -(:period_days + 1), __AS_OF_DATE__)
    AND q.query_id IN (SELECT query_id FROM sf_use_ah)
  GROUP BY q.query_id
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
-- one row per query x table: a query that reads and writes a table counts once for it
qt AS (
  SELECT e.query_id, e.object_id, MAX(e.object_name) AS object_name, MAX(e.user_name) AS user_name,
         MAX(IFF(e.kind = 'read', 1, 0)) AS is_read, MAX(IFF(e.kind = 'write', 1, 0)) AS is_write,
         MIN(e.usage_date) AS usage_date
  FROM sf_use_access_events e
  WHERE e.is_table_like AND e.object_id IS NOT NULL AND e.kind IN ('read', 'write')
  GROUP BY e.query_id, e.object_id
),
-- one row per query, for the user figures: a query on three tables counts once for its user
qq AS (
  SELECT query_id, MAX(user_name) AS user_name, MAX(is_read) AS is_read, MAX(is_write) AS is_write,
         MIN(usage_date) AS usage_date
  FROM qt GROUP BY query_id
),
-- every query once per table and once per user, with how it ran
p AS (
  SELECT 'table' AS row_level, TO_VARCHAR(qt.object_id) AS pkey, CAST(NULL AS VARCHAR) AS other,
         qt.query_id, qt.user_name, qt.is_read, qt.is_write, qt.usage_date, m.shape_hash, m.elapsed_s,
         m.partitions_scanned, m.partitions_total, m.bytes_scanned, m.bytes_spilled
  FROM qt LEFT JOIN sf_use_query_metrics m ON m.query_id = qt.query_id
  UNION ALL
  SELECT 'user', qq.user_name, CAST(NULL AS VARCHAR), qq.query_id, qq.user_name, qq.is_read, qq.is_write,
         qq.usage_date, m.shape_hash, m.elapsed_s, m.partitions_scanned, m.partitions_total, m.bytes_scanned,
         m.bytes_spilled
  FROM qq LEFT JOIN sf_use_query_metrics m ON m.query_id = qq.query_id
),
rk AS (
  SELECT row_level, pkey, ROW_NUMBER() OVER (PARTITION BY row_level ORDER BY COUNT(*) DESC, pkey) AS entity_rank
  FROM p GROUP BY row_level, pkey
),
-- the pairs: each kept table's users and each kept user's tables, with the same figures
pr AS (
  SELECT 'table_user' AS row_level, TO_VARCHAR(qt.object_id) AS pkey, qt.user_name AS other,
         qt.query_id, qt.user_name, qt.is_read, qt.is_write, qt.usage_date, m.shape_hash, m.elapsed_s,
         m.partitions_scanned, m.partitions_total, m.bytes_scanned, m.bytes_spilled
  FROM qt
  JOIN rk ON rk.row_level = 'table' AND rk.pkey = TO_VARCHAR(qt.object_id) AND rk.entity_rank <= :top_n
  LEFT JOIN sf_use_query_metrics m ON m.query_id = qt.query_id
  UNION ALL
  SELECT 'user_table', qt.user_name, TO_VARCHAR(qt.object_id), qt.query_id, qt.user_name, qt.is_read,
         qt.is_write, qt.usage_date, m.shape_hash, m.elapsed_s, m.partitions_scanned, m.partitions_total,
         m.bytes_scanned, m.bytes_spilled
  FROM qt
  JOIN rk ON rk.row_level = 'user' AND rk.pkey = qt.user_name AND rk.entity_rank <= :top_n
  LEFT JOIN sf_use_query_metrics m ON m.query_id = qt.query_id
),
a AS (
  SELECT row_level, pkey, other,
         COUNT(*) AS queries, SUM(is_read) AS read_queries, SUM(is_write) AS write_queries,
         COUNT(DISTINCT usage_date) AS active_days, COUNT(DISTINCT user_name) AS users,
         COUNT(DISTINCT shape_hash) AS shapes, COUNT(elapsed_s) AS timed_queries,
         AVG(elapsed_s) AS avg_elapsed_s, APPROX_PERCENTILE(elapsed_s, 0.9) AS p90_elapsed_s,
         MAX(elapsed_s) AS max_elapsed_s, SUM(elapsed_s) / 3600 AS total_elapsed_h,
         AVG(partitions_scanned) AS avg_partitions_scanned, AVG(partitions_total) AS avg_partitions_total,
         100 * SUM(partitions_scanned) / NULLIF(SUM(partitions_total), 0) AS scan_pct,
         SUM(bytes_scanned) / POWER(1024, 3) AS gb_scanned,
         100 * COUNT(IFF(bytes_spilled > 0, 1, NULL)) / NULLIF(COUNT(elapsed_s), 0) AS spill_pct,
         SUM(bytes_spilled) / POWER(1024, 3) AS gb_spilled
  FROM (SELECT * FROM p UNION ALL SELECT * FROM pr)
  GROUP BY row_level, pkey, other
),
-- tables per user: distinct tables, which the per-query user rows cannot count
ut AS (
  SELECT user_name, COUNT(DISTINCT object_id) AS tables FROM qt GROUP BY user_name
),
r AS (
  SELECT a.*, rk.entity_rank,
         IFF(a.other IS NULL, NULL,
             ROW_NUMBER() OVER (PARTITION BY a.row_level, a.pkey ORDER BY a.queries DESC, a.other)) AS pair_rank
  FROM a
  JOIN rk ON rk.pkey = a.pkey AND rk.row_level = IFF(a.row_level IN ('table', 'table_user'), 'table', 'user')
  WHERE rk.entity_rank <= :top_n
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, r.row_level,
       TRY_TO_NUMBER(IFF(r.row_level IN ('table', 'table_user'), r.pkey, r.other)) AS table_id,
       COALESCE(l.table_fqn, o.object_name) AS table_fqn,
       IFF(r.row_level IN ('user', 'user_table'), r.pkey, r.other) AS user_name,
       r.entity_rank, r.pair_rank, r.queries, r.read_queries, r.write_queries, r.active_days,
       IFF(r.row_level = 'table', r.users, NULL) AS users,
       IFF(r.row_level = 'user', ut.tables, NULL) AS tables,
       r.shapes, r.timed_queries, r.avg_elapsed_s, r.p90_elapsed_s, r.max_elapsed_s, r.total_elapsed_h,
       r.avg_partitions_scanned, r.avg_partitions_total, r.scan_pct, r.gb_scanned, r.spill_pct, r.gb_spilled,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM r
LEFT JOIN (SELECT object_id, MAX(object_name) AS object_name FROM qt GROUP BY object_id) o
  ON TO_VARCHAR(o.object_id) = IFF(r.row_level IN ('table', 'table_user'), r.pkey, r.other)
LEFT JOIN sf_storage_live_tables l ON TO_VARCHAR(l.table_id) = IFF(r.row_level IN ('table', 'table_user'), r.pkey, r.other)
LEFT JOIN ut ON ut.user_name = r.pkey AND r.row_level = 'user'
WHERE r.pair_rank IS NULL OR r.pair_rank <= :top_pairs
UNION ALL
SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS INTEGER), CAST(NULL AS INTEGER), NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       'no_access_history', 'NOT_ASSESSED'
FROM seen WHERE access_rows = 0
ORDER BY row_level, entity_rank, pair_rank
