-- query_id: sf_query_repeated_expensive
-- title: Expensive statements run over and over
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_runs (default 20) runs: least a row needs before it can flag; :warn_credits (default 20)
--   credits: at or above this the row reads WARN; :crit_credits (default 200) credits: at or above this
--   the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash: same text with literals ignored)
--   run at least min_runs times. credits = attributed compute plus query acceleration credits of all
--   its runs; cache_scan_pct = average share of bytes read from the warehouse cache; runs_per_day shows
--   the cadence.
-- healthy: status = OK when a repeated statement costs under warn_credits in the window
-- investigate_if: WARN when credits >= warn_credits; CRITICAL when credits >= crit_credits
-- actions: 1) precompute it as a dynamic table, materialized view or scheduled table the readers query
--   (free); 2) if the text is truly identical and the data changes rarely, let the result cache serve
--   it, see sf_query_result_cache_misses (free); 3) cluster the scanned table on the filter columns
--   (spend)
-- next: none
-- caveats: credits exclude warehouse idle time and queries under about 100 ms;
--   QUERY_ATTRIBUTION_HISTORY lags up to 8 hours. One shape can hide different literal values that each
--   need their own result.
WITH a AS (
  SELECT query_id, query_parameterized_hash, warehouse_id, warehouse_name, user_name, query_tag,
         credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_parameterized_hash IS NOT NULL
),
hot AS (
  -- keep only shapes run often enough before joining the much larger QUERY_HISTORY
  SELECT query_parameterized_hash
  FROM a
  GROUP BY 1
  HAVING COUNT(*) >= :min_runs AND SUM(credits) >= :warn_credits / 10
),
qh AS (
  SELECT query_id, TO_VARCHAR(warehouse_id) AS warehouse_id, query_type, start_time, execution_time,
         bytes_scanned, percentage_scanned_from_cache
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_parameterized_hash IN (SELECT query_parameterized_hash FROM hot)
),
g AS (
  SELECT a.query_parameterized_hash,
         COUNT(*) AS runs, SUM(a.credits) AS credits, AVG(a.credits) AS avg_credits_per_run,
         COUNT(DISTINCT a.user_name) AS distinct_users, COUNT(DISTINCT a.warehouse_name) AS distinct_warehouses,
         -- the busiest warehouse as one id|name pair, so a name never sits next to another warehouse's id
         MODE(TO_VARCHAR(a.warehouse_id) || '|' || a.warehouse_name) AS main_wh,
         MODE(a.user_name) AS main_user_name, MODE(a.query_tag) AS main_query_tag,
         MAX(qh.query_type) AS query_type,
         COUNT(*) / GREATEST(DATEDIFF(day, MIN(qh.start_time), MAX(qh.start_time)), 1) AS runs_per_day,
         AVG(qh.execution_time) / 1000 AS avg_exec_s,
         SUM(qh.bytes_scanned) / POWER(1024, 3) AS scanned_gb,
         100 * AVG(qh.percentage_scanned_from_cache) AS cache_scan_pct,
         MAX_BY(a.query_id, a.credits) AS costliest_query_id
  FROM a
  JOIN hot t ON t.query_parameterized_hash = a.query_parameterized_hash
  LEFT JOIN qh ON qh.query_id = a.query_id
  GROUP BY 1
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, SPLIT_PART(main_wh, '|', 1) AS warehouse_id,
       SPLIT_PART(main_wh, '|', 2) AS warehouse_name, query_parameterized_hash, query_type, runs, runs_per_day,
       distinct_users, distinct_warehouses, main_user_name, main_query_tag, avg_exec_s, scanned_gb,
       cache_scan_pct, credits, avg_credits_per_run, credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       costliest_query_id,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN credits >= :crit_credits THEN 'CRITICAL'
         WHEN credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY credits DESC
