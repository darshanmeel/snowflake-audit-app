-- query_id: sf_query_full_scans
-- title: Statements that scan most partitions of large tables
-- domain: performance   tier: standard
-- entity: query shapes = warehouse_id, query_parameterized_hash
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_partitions (default 1000) partitions: least a row needs before it can flag; :scan_pct
--   (default 80) scan pct: value this check uses; :min_runs (default 5) runs: least a row needs before
--   it can flag; :warn_credits (default 10) credits: at or above this the row reads WARN; :crit_credits
--   (default 100) credits: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash) on one warehouse whose runs
--   touched at least min_partitions micro-partitions and scanned at least scan_pct of them, i.e.
--   pruning did little. avg_scan_pct = partitions_scanned / partitions_total; credits = attributed
--   credits of those runs.
-- healthy: status = OK when full scans are rare or cheap
-- investigate_if: WARN when runs >= min_runs and credits >= warn_credits; CRITICAL when credits >=
--   crit_credits
-- actions: 1) add or tighten a filter on a column the table is naturally ordered by (load date, event
--   time) (free); 2) cluster the table on the filter columns, see sf_storage_clustering_candidates for
--   the table view (spend); 3) search optimization for selective point lookups (spend)
-- next: none
-- caveats: partition counts are summed over every table in the statement, so a join with one small
--   fully scanned table looks like a full scan. Some statements (full refreshes, exports) must read
--   everything.
WITH qh AS (
  SELECT query_id, query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name,
         user_name, database_name, schema_name, query_type, start_time, execution_time, bytes_scanned,
         partitions_scanned, partitions_total
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND partitions_total >= :min_partitions
    AND partitions_scanned >= partitions_total * :scan_pct / 100
    AND query_type IN ('SELECT', 'INSERT', 'MERGE', 'UPDATE', 'DELETE', 'CREATE_TABLE_AS_SELECT')
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
g AS (
  SELECT qh.query_parameterized_hash, qh.warehouse_id, MAX(qh.warehouse_name) AS warehouse_name,
         MODE(qh.database_name) AS database_name, MODE(qh.schema_name) AS schema_name,
         MODE(qh.query_type) AS query_type, COUNT(*) AS runs,
         AVG(qh.partitions_total) AS avg_partitions_total,
         100 * SUM(qh.partitions_scanned) / NULLIF(SUM(qh.partitions_total), 0) AS avg_scan_pct,
         SUM(qh.bytes_scanned) / POWER(1024, 4) AS scanned_tb,
         SUM(qh.execution_time) / 3600000 AS exec_hours,
         COUNT(DISTINCT qh.user_name) AS distinct_users,
         MAX_BY(qh.query_id, qh.bytes_scanned) AS biggest_query_id,
         SUM(a.credits) AS credits
  FROM qh LEFT JOIN attr a ON a.query_id = qh.query_id
  GROUP BY qh.query_parameterized_hash, qh.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       query_parameterized_hash, query_type, database_name, schema_name, runs, avg_partitions_total,
       avg_scan_pct, scanned_tb, exec_hours, distinct_users, biggest_query_id,
       credits, credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN credits >= :crit_credits THEN 'CRITICAL'
         WHEN runs >= :min_runs AND credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY credits DESC NULLS LAST, scanned_tb DESC
