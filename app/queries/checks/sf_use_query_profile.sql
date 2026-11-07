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
WITH __INCLUDE_sf_use_access_events__,
__INCLUDE_sf_use_query_metrics__,
__INCLUDE_sf_storage_live_tables__,
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
