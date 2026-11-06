-- query_id: sf_query_full_scans
-- title: Statement shapes that scan most partitions of a large table
-- domain: performance   tier: standard
-- entity: query shapes = warehouse_id, query_parameterized_hash
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_partitions (default 1000) partitions: least a row needs before it can flag; :scan_pct
--   (default 80) scan pct: value this check uses; :min_runs (default 5) runs: least a row needs before
--   it can flag; :warn_credits (default 10) credits: at or above this the row reads WARN; :crit_credits
--   (default 100) credits: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash) on one warehouse that, on at least one
--   table, read at least min_partitions micro-partitions per run and scanned at least scan_pct of them over
--   the window, i.e. pruning did little on that table. table_fqn is the table it scanned most;
--   avg_partitions_total and avg_scan_pct are that table's; tables_fully_scanned counts the tables that
--   qualify. credits = attributed credits of all the shape's runs on that warehouse.
-- healthy: status = OK when full scans are rare or cheap
-- not_assessed_reasons: no_attribution: Snowflake attributed no credits to this shape (adaptive warehouses,
--   queries under about 100 ms, or attribution still lagging), so it cannot be judged by cost
-- investigate_if: WARN when runs >= min_runs and credits >= warn_credits; CRITICAL when credits >=
--   crit_credits
-- actions: 1) add or tighten a filter on a column the table is naturally ordered by (load date, event
--   time) (free); 2) cluster the table on the filter columns, see sf_storage_clustering_candidates for
--   the table view (spend); 3) search optimization for selective point lookups (spend)
-- next: none
-- caveats: judged per table, so a large table scanned in full still shows when the statement also prunes
--   another, and small tables do not add up to a false full scan. Judged over the window, so a shape that
--   rarely scans in full can stay under scan_pct. Only the 1,000 longest scans per query are recorded, and
--   hybrid tables are not. Some statements (full refreshes, exports) must read everything.
WITH tbl AS (
  -- per table: a statement-wide sum would hide one full scan behind a table that prunes well
  SELECT query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, table_id,
         MAX(database_name || '.' || schema_name || '.' || table_name) AS table_fqn,
         SUM(partitions_scanned) AS ps, SUM(partitions_pruned) AS pp, SUM(num_queries) AS table_runs
  FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_QUERY_PRUNING_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND interval_start_time < __AS_OF_DATE__
    AND query_parameterized_hash IS NOT NULL AND warehouse_id IS NOT NULL
  GROUP BY 1, 2, 3
),
scanned AS (
  SELECT query_parameterized_hash, warehouse_id, table_id, table_fqn,
         (ps + pp) / NULLIF(table_runs, 0) AS avg_partitions_total,
         100 * ps / NULLIF(ps + pp, 0) AS avg_scan_pct,
         COUNT(*) OVER (PARTITION BY query_parameterized_hash, warehouse_id) AS tables_fully_scanned,
         ROW_NUMBER() OVER (PARTITION BY query_parameterized_hash, warehouse_id ORDER BY ps DESC, table_id) AS rn
  FROM tbl
  WHERE (ps + pp) / NULLIF(table_runs, 0) >= :min_partitions
    AND 100 * ps / NULLIF(ps + pp, 0) >= :scan_pct
),
worst AS (SELECT * FROM scanned WHERE rn = 1),
qh AS (
  SELECT q.query_id, q.query_parameterized_hash, TO_VARCHAR(q.warehouse_id) AS warehouse_id, q.warehouse_name,
         q.user_name, q.database_name, q.schema_name, q.query_type, q.execution_time, q.bytes_scanned
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  JOIN worst w ON w.query_parameterized_hash = q.query_parameterized_hash
              AND w.warehouse_id = TO_VARCHAR(q.warehouse_id)
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND q.query_type IN ('SELECT', 'INSERT', 'MERGE', 'UPDATE', 'DELETE', 'CREATE_TABLE_AS_SELECT')
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
         SUM(qh.bytes_scanned) / POWER(1024, 4) AS scanned_tb,
         SUM(qh.execution_time) / 3600000 AS exec_hours,
         COUNT(DISTINCT qh.user_name) AS distinct_users,
         MAX_BY(qh.query_id, qh.bytes_scanned) AS biggest_query_id,
         SUM(a.credits) AS credits
  FROM qh LEFT JOIN attr a ON a.query_id = qh.query_id
  GROUP BY qh.query_parameterized_hash, qh.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.warehouse_id, g.warehouse_name,
       g.query_parameterized_hash, g.query_type, g.database_name, g.schema_name, w.table_id, w.table_fqn,
       w.tables_fully_scanned, g.runs, w.avg_partitions_total,
       w.avg_scan_pct, g.scanned_tb, g.exec_hours, g.distinct_users, g.biggest_query_id,
       g.credits, g.credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       IFF(g.credits IS NULL, 'no_attribution', NULL) AS not_assessed_reason,
       CASE
         WHEN g.credits IS NULL THEN 'NOT_ASSESSED'
         WHEN g.credits >= :crit_credits THEN 'CRITICAL'
         WHEN g.runs >= :min_runs AND g.credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
JOIN worst w ON w.query_parameterized_hash = g.query_parameterized_hash AND w.warehouse_id = g.warehouse_id
ORDER BY g.credits DESC NULLS LAST, g.scanned_tb DESC
