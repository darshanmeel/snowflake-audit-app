-- query_id: sf_use_top_query_shapes
-- title: The top query shapes on each busy table and of each busy user, with the tables and columns they use
-- domain: performance   tier: standard
-- entity: query shapes = row_level, table_fqn, user_name, shape_hash
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; Enterprise edition
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 25) tables and users: the busiest of each by queries, as in
--   sf_use_query_profile; :top_shapes (default 10) shapes kept per table or user for each ranking
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one query shape on one of the :top_n busiest tables (row_level = table) or of one
--   of the :top_n busiest users (row_level = user). A shape is Snowflake's query_parameterized_hash: the
--   same statement with different literals, so a dashboard query run 500 times is one row. A shape is
--   kept when it is in the top :top_shapes of its table or user by runs (rank_runs), total time
--   (rank_time), partitions scanned (rank_scanned) or bytes spilled (rank_spilled). Its lineage covers
--   every run of the shape in the window: tables_read and tables_written (from ACCESS_HISTORY), and the
--   columns it filtered (where_columns) and joined (join_columns) on, from COLUMN_QUERY_PRUNING_HISTORY.
--   slowest_query_id is the slowest single run, to open in Snowsight's query profile. No query text is kept.
-- healthy: status = OK on every listed row; this check describes the heaviest shapes, it does not judge them.
-- investigate_if: NOT_ASSESSED when ACCESS_HISTORY has no rows in the window.
-- actions: 1) open slowest_query_id in Snowsight's query profile, and filter or cluster on the
--   where_columns of a shape that scans most partitions (free); 2) give a shape that spills to remote
--   storage a larger warehouse, or split it (config).
-- next: none
-- empty_if: edition_too_low, role_cannot_see, no_activity
-- not_assessed_reasons: no_access_history: ACCESS_HISTORY has no rows in the window (Standard edition, or the
--   role cannot see it), so which queries used a table cannot be told
-- caveats: time, scan and spill are the whole query's, not one table's share. GROUP BY and SELECT columns
--   are not in any usage view; where_columns and join_columns come only from queries that scanned
--   micro-partitions. A query with no parameterized hash is its own shape (one run). Lists keep 10 names.
--   ACCESS_HISTORY records successful queries only and lags up to 3 hours.
WITH __INCLUDE_sf_use_access_events__,
__INCLUDE_sf_use_query_metrics__,
__INCLUDE_sf_storage_live_tables__,
seen AS (
  SELECT access_rows FROM sf_use_access_seen
),
qt AS (
  SELECT e.query_id, e.object_id, MAX(e.object_name) AS object_name, MAX(e.user_name) AS user_name,
         MAX(IFF(e.kind = 'read', 1, 0)) AS is_read, MAX(IFF(e.kind = 'write', 1, 0)) AS is_write
  FROM sf_use_access_events e
  WHERE e.is_table_like AND e.object_id IS NOT NULL AND e.kind IN ('read', 'write')
  GROUP BY e.query_id, e.object_id
),
qm AS (
  SELECT m.*, COALESCE(m.shape_hash, 'query:' || m.query_id) AS shape
  FROM sf_use_query_metrics m
),
-- the same ranking as sf_use_query_profile: queries per table, and per user over distinct queries
rk AS (
  SELECT 'table' AS row_level, TO_VARCHAR(object_id) AS pkey,
         ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, TO_VARCHAR(object_id)) AS entity_rank
  FROM qt GROUP BY object_id
  UNION ALL
  SELECT 'user', user_name, ROW_NUMBER() OVER (ORDER BY COUNT(DISTINCT query_id) DESC, user_name)
  FROM qt GROUP BY user_name
),
p AS (
  SELECT 'table' AS row_level, TO_VARCHAR(qt.object_id) AS pkey, qt.query_id, qt.user_name
  FROM qt
  UNION ALL
  SELECT DISTINCT 'user', qt.user_name, qt.query_id, qt.user_name
  FROM qt
),
g AS (
  SELECT p.row_level, p.pkey, rk.entity_rank, qm.shape, MAX(qm.shape_hash) AS shape_hash,
         MAX(qm.query_type) AS query_type, MAX(qm.warehouse_name) AS warehouse_name,
         COUNT(*) AS runs, COUNT(DISTINCT p.user_name) AS users,
         SUM(qm.elapsed_s) AS total_elapsed_s, AVG(qm.elapsed_s) AS avg_elapsed_s, MAX(qm.elapsed_s) AS max_elapsed_s,
         MAX_BY(qm.query_id, qm.elapsed_s) AS slowest_query_id,
         SUM(qm.partitions_scanned) AS partitions_scanned, AVG(qm.partitions_scanned) AS avg_partitions_scanned,
         100 * SUM(qm.partitions_scanned) / NULLIF(SUM(qm.partitions_total), 0) AS scan_pct,
         SUM(qm.bytes_scanned) / POWER(1024, 3) AS gb_scanned,
         SUM(qm.bytes_spilled) / POWER(1024, 3) AS gb_spilled,
         SUM(qm.bytes_spilled_remote) / POWER(1024, 3) AS gb_spilled_remote,
         COUNT(IFF(qm.bytes_spilled > 0, 1, NULL)) AS spill_runs
  FROM p
  JOIN rk ON rk.row_level = p.row_level AND rk.pkey = p.pkey AND rk.entity_rank <= :top_n
  JOIN qm ON qm.query_id = p.query_id
  GROUP BY p.row_level, p.pkey, rk.entity_rank, qm.shape
),
gr AS (
  SELECT g.*,
         ROW_NUMBER() OVER (PARTITION BY row_level, pkey ORDER BY runs DESC, shape) AS rank_runs,
         ROW_NUMBER() OVER (PARTITION BY row_level, pkey ORDER BY total_elapsed_s DESC NULLS LAST, shape) AS rank_time,
         ROW_NUMBER() OVER (PARTITION BY row_level, pkey ORDER BY partitions_scanned DESC NULLS LAST, shape) AS rank_scanned,
         IFF(gb_spilled > 0, ROW_NUMBER() OVER (PARTITION BY row_level, pkey ORDER BY gb_spilled DESC NULLS LAST, shape), NULL) AS rank_spilled
  FROM g
),
kept AS (
  SELECT * FROM gr
  WHERE rank_runs <= :top_shapes OR rank_time <= :top_shapes OR rank_scanned <= :top_shapes
     OR rank_spilled <= :top_shapes
),
-- lineage of each kept shape over all its runs: the tables it read and wrote
st AS (
  SELECT qm.shape, qt.object_id, MAX(qt.object_name) AS object_name, MAX(qt.is_read) AS is_read,
         MAX(qt.is_write) AS is_write, COUNT(*) AS q
  FROM qt JOIN qm ON qm.query_id = qt.query_id
  WHERE qm.shape IN (SELECT shape FROM kept)
  GROUP BY qm.shape, qt.object_id
),
-- one name list per shape and kind, 10 names, busiest first
stl AS (
  SELECT shape, IFF(is_read = 1, 'read', 'write') AS kind,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(object_name) WITHIN GROUP (ORDER BY q DESC, object_name), 0, 10), ', ') AS names
  FROM (SELECT shape, object_name, q, 1 AS is_read FROM st WHERE is_read = 1
        UNION ALL SELECT shape, object_name, q, 0 FROM st WHERE is_write = 1)
  GROUP BY shape, kind
),
-- the columns each shape filtered and joined on
cu AS (
  SELECT query_parameterized_hash AS shape, UPPER(access_type) AS access_type,
         UPPER(table_name) || '.' || UPPER(column_name) AS col, SUM(num_queries) AS q
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
    AND UPPER(access_type) IN ('WHERE', 'JOIN') AND column_name IS NOT NULL
    AND query_parameterized_hash IN (SELECT shape FROM kept)
  GROUP BY 1, 2, 3
),
cul AS (
  SELECT shape, access_type,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(col) WITHIN GROUP (ORDER BY q DESC, col), 0, 10), ', ') AS names
  FROM cu GROUP BY shape, access_type
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, k.row_level,
       IFF(k.row_level = 'table', TRY_TO_NUMBER(k.pkey), NULL) AS table_id,
       IFF(k.row_level = 'table', COALESCE(l.table_fqn, o.object_name), NULL) AS table_fqn,
       IFF(k.row_level = 'user', k.pkey, NULL) AS user_name,
       k.entity_rank, k.shape_hash, k.query_type, k.warehouse_name, k.runs, k.users, k.total_elapsed_s,
       k.avg_elapsed_s, k.max_elapsed_s, k.slowest_query_id, k.partitions_scanned, k.avg_partitions_scanned,
       k.scan_pct, k.gb_scanned, k.gb_spilled, k.gb_spilled_remote, k.spill_runs,
       k.rank_runs, k.rank_time, k.rank_scanned, k.rank_spilled,
       sr.names AS tables_read, sw.names AS tables_written, cw.names AS where_columns, cj.names AS join_columns,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM kept k
LEFT JOIN stl sr ON sr.shape = k.shape AND sr.kind = 'read'
LEFT JOIN stl sw ON sw.shape = k.shape AND sw.kind = 'write'
LEFT JOIN cul cw ON cw.shape = k.shape AND cw.access_type = 'WHERE'
LEFT JOIN cul cj ON cj.shape = k.shape AND cj.access_type = 'JOIN'
LEFT JOIN (SELECT object_id, MAX(object_name) AS object_name FROM qt GROUP BY object_id) o
  ON k.row_level = 'table' AND TO_VARCHAR(o.object_id) = k.pkey
LEFT JOIN sf_storage_live_tables l ON k.row_level = 'table' AND TO_VARCHAR(l.table_id) = k.pkey
UNION ALL
SELECT :period_days, __ACCOUNT_ID__, CAST(NULL AS VARCHAR), CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS INTEGER), CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), NULL, NULL, NULL, NULL, NULL, CAST(NULL AS VARCHAR), NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR),
       CAST(NULL AS VARCHAR), CAST(NULL AS VARCHAR), 'no_access_history', 'NOT_ASSESSED'
FROM seen WHERE access_rows = 0
ORDER BY row_level, entity_rank, rank_runs
