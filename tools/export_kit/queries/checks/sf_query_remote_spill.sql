-- query_id: sf_query_remote_spill
-- title: Statements spilling to remote storage
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_remote_gb (default 10) remote gb: at or above this the row reads WARN; :crit_remote_gb
--   (default 500) remote gb: at or above this the row reads CRITICAL; :crit_credits (default 100)
--   credits: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash) on one warehouse that spilled to
--   remote storage at least once. Remote spill means memory and local SSD were both exhausted, which
--   can make a query many times slower. credits = attributed credits of its spilling runs.
-- healthy: status = OK when total remote spill stays under warn_remote_gb
-- investigate_if: WARN when remote_spill_gb >= warn_remote_gb; CRITICAL when >= crit_remote_gb or the
--   spilling runs used >= crit_credits
-- actions: 1) reduce the data per operator (filter earlier, fewer columns, avoid huge ORDER BY /
--   DISTINCT / window partitions, split the job) (free); 2) run it on a larger or Snowpark-optimized
--   warehouse (config)
-- next: none
-- caveats: grouped by warehouse name and statement shape; the size shown is the most recent run's.
--   Credits exclude idle time and queries under about 100 ms, and lag up to 8 hours.
WITH qh AS (
  SELECT query_id, query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name,
         warehouse_size, user_name, start_time, execution_time,
         bytes_spilled_to_local_storage AS local_b, bytes_spilled_to_remote_storage AS remote_b, bytes_scanned
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND bytes_spilled_to_remote_storage > 0
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
g AS (
  SELECT qh.query_parameterized_hash, qh.warehouse_id, MAX(qh.warehouse_name) AS warehouse_name,
         MAX_BY(qh.warehouse_size, qh.start_time) AS warehouse_size,
         COUNT(*) AS spilling_runs,
         SUM(qh.remote_b) / POWER(1024, 3) AS remote_spill_gb,
         SUM(qh.local_b) / POWER(1024, 3) AS local_spill_gb,
         MAX(qh.remote_b) / POWER(1024, 3) AS max_remote_spill_gb_per_run,
         SUM(qh.bytes_scanned) / POWER(1024, 3) AS scanned_gb,
         SUM(qh.execution_time) / 3600000 AS exec_hours,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT qh.user_name), 0, 10), ', ') AS users,
         MAX_BY(qh.query_id, qh.remote_b) AS worst_query_id,
         MAX(qh.start_time) AS last_seen,
         SUM(a.credits) AS credits
  FROM qh LEFT JOIN attr a ON a.query_id = qh.query_id
  GROUP BY qh.query_parameterized_hash, qh.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, query_parameterized_hash, spilling_runs, remote_spill_gb, local_spill_gb,
       max_remote_spill_gb_per_run, scanned_gb, exec_hours, users, worst_query_id,
       last_seen, credits, credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN remote_spill_gb >= :crit_remote_gb OR credits >= :crit_credits THEN 'CRITICAL'
         WHEN remote_spill_gb >= :warn_remote_gb THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY remote_spill_gb DESC
