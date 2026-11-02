-- query_id: sf_use_table_columns
-- title: The columns queries filter and join on, per table
-- domain: storage   tier: standard
-- entity: table columns = table_fqn, column_name, access_type
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 200) tables: only the tables with the most such queries are kept;
--   :top_columns (default 10) columns: kept per table and access type
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one column of a table x how queries used it (access_type WHERE or JOIN). queries
--   counts the queries that filtered or joined on it; prune_pct is the share of micro-partitions those
--   queries skipped, so a busy WHERE column with a low prune_pct is a clustering or search optimization
--   candidate. table_rank 1 = the table with the most such queries.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: sf_storage_clustering_candidates
-- caveats: Snowflake records WHERE and JOIN columns only; GROUP BY and SELECT columns are not in any usage
--   view. Hybrid tables are left out, and only queries that scanned micro-partitions count. Lags up to 4
--   hours.
WITH c AS (
  SELECT table_id, UPPER(database_name) AS database_name, UPPER(schema_name) AS schema_name,
         UPPER(table_name) AS table_name, UPPER(column_name) AS column_name, UPPER(access_type) AS access_type,
         SUM(num_queries) AS queries, SUM(partitions_scanned) AS partitions_scanned,
         SUM(partitions_pruned) AS partitions_pruned, SUM(aggregate_query_execution_time) / 1000 AS exec_s,
         COUNT(DISTINCT warehouse_id) AS warehouses, MAX(interval_end_time) AS last_used
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
    AND UPPER(access_type) IN ('WHERE', 'JOIN') AND column_name IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6
),
t AS (
  SELECT table_id, DENSE_RANK() OVER (ORDER BY SUM(queries) DESC, table_id) AS table_rank,
         SUM(queries) AS table_queries
  FROM c GROUP BY table_id
),
r AS (
  SELECT c.*, t.table_rank, t.table_queries,
         ROW_NUMBER() OVER (PARTITION BY c.table_id, c.access_type ORDER BY c.queries DESC, c.column_name) AS column_rank
  FROM c JOIN t ON t.table_id = c.table_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, table_id, database_name, schema_name, table_name,
       database_name || '.' || schema_name || '.' || table_name AS table_fqn, column_name, access_type, queries,
       partitions_scanned, partitions_pruned,
       ROUND(100 * partitions_pruned / NULLIF(partitions_scanned + partitions_pruned, 0), 1) AS prune_pct,
       exec_s, warehouses, last_used, table_rank, table_queries, column_rank,
       CAST(NULL AS VARCHAR) AS not_assessed_reason, 'OK' AS status
FROM r
WHERE table_rank <= :top_n AND column_rank <= :top_columns
ORDER BY table_rank, access_type DESC, queries DESC
