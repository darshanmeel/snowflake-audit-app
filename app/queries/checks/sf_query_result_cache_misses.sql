-- query_id: sf_query_result_cache_misses
-- title: Identical queries re-run instead of served from the result cache
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :reuse_window_hours (default 24) reuse window hours: value this check uses; :min_misses
--   (default 10) misses: least a row needs before it can flag; :warn_credits (default 5) credits: at or
--   above this the row reads WARN; :crit_credits (default 50) credits: at or above this the row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one exact query text (query_hash) that ran again within reuse_window_hours of an
--   earlier successful run. missed_runs = repeats that scanned table data on a warehouse;
--   no_scan_repeats = repeats that read nothing (result cache or metadata answers). credits =
--   attributed credits of the missed runs.
-- healthy: status = OK when repeated identical SELECTs are mostly answered without a scan or cost
--   little
-- investigate_if: WARN when missed_runs >= min_misses and credits >= warn_credits; CRITICAL when
--   missed_runs >= min_misses and credits >= crit_credits
-- actions: 1) check USE_CACHED_RESULT is not turned off for the user or tool (free); 2) remove per-run
--   differences that defeat the cache (CURRENT_TIMESTAMP, RANDOM, changing comments or literals)
--   (free); 3) if the base tables change every few minutes, cache on a schedule with a dynamic table
--   instead (config)
-- next: none
-- caveats: a miss is inferred (bytes scanned > 0), Snowflake has no cache-hit flag. The cache is
--   dropped whenever the underlying data changes, so some misses are correct. Credits exclude queries
--   under about 100 ms.
WITH qh AS (
  SELECT query_id, query_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name, user_name,
         start_time, bytes_scanned, execution_time,
         LAG(start_time) OVER (PARTITION BY query_hash ORDER BY start_time) AS prev_start
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'SELECT' AND execution_status = 'SUCCESS' AND query_hash IS NOT NULL
),
rep AS (
  SELECT qh.*, bytes_scanned > 0 AND warehouse_name IS NOT NULL AS missed
  FROM qh
  WHERE prev_start IS NOT NULL AND DATEDIFF(second, prev_start, start_time) <= :reuse_window_hours * 3600
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
g AS (
  -- one id|name pair, so the name never comes from another warehouse than the id
  SELECT r.query_hash, MODE(TO_VARCHAR(r.warehouse_id) || '|' || COALESCE(r.warehouse_name, '')) AS main_wh,
         COUNT(*) AS repeats, COUNT_IF(r.missed) AS missed_runs, COUNT_IF(NOT r.missed) AS no_scan_repeats,
         COUNT(DISTINCT r.user_name) AS distinct_users, MODE(r.user_name) AS main_user_name,
         SUM(IFF(r.missed, r.bytes_scanned, 0)) / POWER(1024, 3) AS missed_scanned_gb,
         SUM(IFF(r.missed, r.execution_time, 0)) / 3600000 AS missed_exec_hours,
         SUM(IFF(r.missed, a.credits, 0)) AS credits,
         MAX(r.start_time) AS last_seen
  FROM rep r LEFT JOIN attr a ON a.query_id = r.query_id
  GROUP BY 1
  HAVING COUNT_IF(r.missed) > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       NULLIF(SPLIT_PART(main_wh, '|', 1), '') AS warehouse_id, NULLIF(SPLIT_PART(main_wh, '|', 2), '') AS warehouse_name,
       query_hash, repeats, missed_runs, no_scan_repeats,
       100 * missed_runs / NULLIF(repeats, 0) AS miss_pct,
       distinct_users, main_user_name, missed_scanned_gb, missed_exec_hours,
       credits, credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       last_seen,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN missed_runs >= :min_misses AND credits >= :crit_credits THEN 'CRITICAL'
         WHEN missed_runs >= :min_misses AND credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY credits DESC NULLS LAST, missed_runs DESC
