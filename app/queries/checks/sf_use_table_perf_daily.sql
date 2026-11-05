-- query_id: sf_use_table_perf_daily
-- title: Each busy or clustered table, day by day: query time, waiting, partitions skipped and clustering credits
-- domain: performance   tier: standard
-- entity: tables = table_fqn
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_PRUNING_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS,
--   SNOWFLAKE.ACCOUNT_USAGE.TABLES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30, capped at 90) days of history the check looks at, counted back from the
--   export date; :top_n (default 50) tables kept by most queries, then most rows changed, as in
--   sf_use_table_daily; :top_clustering (default 20) tables kept by most clustering credits, so a costly table
--   that is rarely read is not missed
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one kept table on one day, with quiet days included so a chart has no gaps. queries,
--   elapsed_s, compile_s and exec_s are the day's sums from TABLE_QUERY_PRUNING_HISTORY. avg_exec_s is
--   execution time per query. avg_wait_s is elapsed minus compile and execution per query: queueing, locks
--   and other time the query did no work; a high figure points at the warehouse, not the table. Both are NULL
--   on a day with no queries. prune_pct is partitions skipped over all partitions from TABLE_PRUNING_HISTORY,
--   from the day's sums, NULL on a day with no scans. clustering_credits and est_clustering_usd_list price
--   the day's automatic clustering as sf_storage_clustering_value does. rank_basis says why the table is
--   here: busy or clustering.
-- healthy: status is always OK: this is a trend series, not a finding.
-- investigate_if: never flags. Read a day where avg_exec_s rises or prune_pct falls against the days around
--   it, next to that day's rows changed and DDL in sf_use_table_daily.
-- actions: 1) when execution time rises and prune_pct falls, compare the filters of the table's top shapes
--   with its clustering key (free); 2) when avg_wait_s rises and execution does not, look at the warehouse in
--   Queries > Waiting (free); 3) when clustering credits rise with DML, batch the DML or coarsen the key (config).
-- next: sf_use_top_query_shapes, sf_storage_clustering_value
-- empty_if: role_cannot_see, no_activity, ingestion_lag
-- caveats: a query's time is the whole query's, so a join counts in full for each table it reads; never add
--   time across tables. Only the 1,000 longest scans per query are recorded, and hybrid tables are not. Query
--   and pruning views lag 4 to 6 hours and clustering 3 hours. Days run to the day before the export date, so
--   no partial today. Query compute and storage are not here: Snowflake has no per-table daily figure for
--   either. Without ACCESS_HISTORY (Standard edition) the busy tables rank by rows changed alone, as in
--   sf_use_table_daily; the figures here still show.
WITH __INCLUDE_sf_use_access_events__,
__INCLUDE_sf_storage_live_tables__,
days AS (
  SELECT DATEADD(day, -ROW_NUMBER() OVER (ORDER BY seq4()), __AS_OF_DATE__) AS d
  FROM TABLE(GENERATOR(ROWCOUNT => 400))
),
win AS (
  SELECT d FROM days WHERE d >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__)
),
qp_d AS (
  SELECT table_id, DATE(interval_start_time) AS usage_date,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name,
         SUM(num_queries) AS queries, SUM(aggregate_query_elapsed_time) AS elapsed_ms,
         SUM(aggregate_query_compilation_time) AS compile_ms, SUM(aggregate_query_execution_time) AS exec_ms
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__ AND table_id IS NOT NULL
  GROUP BY table_id, DATE(interval_start_time)
),
pr_d AS (
  SELECT table_id, DATE(start_time) AS usage_date,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name,
         SUM(num_scans) AS num_scans, SUM(partitions_scanned) AS partitions_scanned,
         SUM(partitions_pruned) AS partitions_pruned
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_PRUNING_HISTORY
  WHERE start_time >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND table_id IS NOT NULL
  GROUP BY table_id, DATE(start_time)
),
cl_d AS (
  SELECT table_id, DATE(start_time) AS usage_date,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name,
         SUM(credits_used) AS credits, SUM(num_bytes_reclustered) AS bytes_reclustered
  FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
  WHERE start_time >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND table_id IS NOT NULL
  GROUP BY table_id, DATE(start_time)
),
dml_tot AS (
  SELECT table_id, SUM(COALESCE(rows_added, 0) + COALESCE(rows_removed, 0) + COALESCE(rows_updated, 0)) AS dml_rows,
         MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_DML_HISTORY
  WHERE start_time >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND table_id IS NOT NULL
  GROUP BY table_id
),
ah_tot AS (
  SELECT object_id AS table_id, COUNT(DISTINCT query_id) AS queries, MAX(object_name) AS object_name
  FROM sf_use_access_events
  WHERE is_table_like AND object_id IS NOT NULL
    AND usage_date >= DATEADD(day, -LEAST(:period_days, 90), __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY object_id
),
busy AS (
  -- the ranking of sf_use_table_daily, so its tables are the ones kept here
  SELECT COALESCE(a.table_id, m.table_id) AS table_id,
         ROW_NUMBER() OVER (ORDER BY COALESCE(a.queries, 0) DESC, COALESCE(m.dml_rows, 0) DESC,
                                     COALESCE(a.table_id, m.table_id)) AS busy_rank
  FROM ah_tot a
  FULL OUTER JOIN dml_tot m ON m.table_id = a.table_id
),
clus AS (
  SELECT table_id, ROW_NUMBER() OVER (ORDER BY SUM(credits) DESC, table_id) AS clustering_rank
  FROM cl_d
  GROUP BY table_id
),
kept AS (
  SELECT COALESCE(b.table_id, c.table_id) AS table_id, b.busy_rank, c.clustering_rank
  FROM busy b
  FULL OUTER JOIN clus c ON c.table_id = b.table_id
  WHERE b.busy_rank <= :top_n OR c.clustering_rank <= :top_clustering
),
top AS (
  SELECT table_id, IFF(busy_rank <= :top_n, 'busy', 'clustering') AS rank_basis,
         ROW_NUMBER() OVER (ORDER BY IFF(busy_rank <= :top_n, busy_rank, NULL) NULLS LAST, clustering_rank,
                                     table_id) AS table_rank
  FROM kept
),
hist_names AS (
  -- a dropped table has no live row: its name comes from the history views
  SELECT table_id, MAX(database_name) AS database_name, MAX(schema_name) AS schema_name, MAX(table_name) AS table_name
  FROM (
    SELECT table_id, database_name, schema_name, table_name FROM dml_tot
    UNION ALL SELECT table_id, database_name, schema_name, table_name FROM qp_d
    UNION ALL SELECT table_id, database_name, schema_name, table_name FROM pr_d
    UNION ALL SELECT table_id, database_name, schema_name, table_name FROM cl_d
  ) u
  GROUP BY table_id
),
names AS (
  -- one name per table, fixed priority as in sf_use_table_daily: live table, history, then ACCESS_HISTORY
  SELECT t.table_id,
         COALESCE(l.database_name, h.database_name, NULLIF(SPLIT_PART(a.object_name, '.', 1), '')) AS database_name,
         COALESCE(l.schema_name, h.schema_name, NULLIF(SPLIT_PART(a.object_name, '.', 2), '')) AS schema_name,
         COALESCE(l.table_name, h.table_name, NULLIF(SPLIT_PART(a.object_name, '.', 3), '')) AS table_name
  FROM top t
  LEFT JOIN sf_storage_live_tables l ON l.table_id = t.table_id
  LEFT JOIN hist_names h ON h.table_id = t.table_id
  LEFT JOIN ah_tot a ON a.table_id = t.table_id
),
daily AS (
  SELECT t.table_id, t.table_rank, t.rank_basis, w.d AS usage_date,
         COALESCE(q.queries, 0) AS queries, q.elapsed_ms, q.compile_ms, q.exec_ms,
         COALESCE(p.num_scans, 0) AS num_scans, COALESCE(p.partitions_scanned, 0) AS partitions_scanned,
         COALESCE(p.partitions_pruned, 0) AS partitions_pruned,
         COALESCE(c.credits, 0) AS clustering_credits, COALESCE(c.bytes_reclustered, 0) AS bytes_reclustered
  FROM top t
  CROSS JOIN win w
  LEFT JOIN qp_d q ON q.table_id = t.table_id AND q.usage_date = w.d
  LEFT JOIN pr_d p ON p.table_id = t.table_id AND p.usage_date = w.d
  LEFT JOIN cl_d c ON c.table_id = t.table_id AND c.usage_date = w.d
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, n.usage_date,
       m.database_name, m.schema_name,
       COALESCE(m.table_name, 'table (' || n.table_id || ')') AS table_name,
       n.table_id,
       COALESCE(m.database_name || '.' || m.schema_name || '.' || m.table_name,
                'table (' || n.table_id || ')') AS table_fqn,
       n.table_rank, n.rank_basis,
       n.queries,
       n.elapsed_ms / 1000 AS elapsed_s, n.compile_ms / 1000 AS compile_s, n.exec_ms / 1000 AS exec_s,
       n.exec_ms / 1000 / NULLIF(n.queries, 0) AS avg_exec_s,
       GREATEST(n.elapsed_ms - COALESCE(n.compile_ms, 0) - COALESCE(n.exec_ms, 0), 0) / 1000 / NULLIF(n.queries, 0) AS avg_wait_s,
       n.num_scans, n.partitions_scanned, n.partitions_pruned,
       100 * n.partitions_pruned / NULLIF(n.partitions_scanned + n.partitions_pruned, 0) AS prune_pct,
       n.clustering_credits, n.bytes_reclustered,
       n.clustering_credits * __CREDIT_PRICE__ AS est_clustering_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       'OK' AS status
FROM daily n
JOIN names m ON m.table_id = n.table_id
ORDER BY n.table_rank, n.table_id, n.usage_date
