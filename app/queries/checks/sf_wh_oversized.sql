-- query_id: sf_wh_oversized
-- title: Large warehouses that mostly run small queries
-- domain: compute   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_credits_per_hour (default 8) credits per hour: least a row needs before it can flag;
--   :small_scan_gb (default 1) small scan gb: value this check uses; :small_exec_s (default 10) small
--   exec s: value this check uses; :min_queries (default 200) queries: least a row needs before it can
--   flag; :warn_small_pct (default 90) small pct: at or above this the row reads WARN; :crit_small_pct
--   (default 97) small pct: at or above this the row reads CRITICAL; :warn_saving_credits (default 50)
--   saving credits: at or above this the row reads WARN; :crit_saving_credits (default 500) saving
--   credits: at or above this the row reads CRITICAL; :max_spilling_pct (default 5) spilling pct: at or
--   above this the warehouse needs its size and reads OK
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse at its current size. small_query_pct = share of its successful
--   queries at that size that scanned under small_scan_gb, ran under small_exec_s and did not spill.
--   est_saving_credits = half its compute credits at this size (never more than its spend), what one size
--   down saves if run times stay flat; 0 when the warehouse spills (spill_reason says why).
-- healthy: status = OK when the warehouse is below Large (min_credits_per_hour), its queries are not
--   mostly small, or it spills: any remote spill, or max_spilling_pct of its queries spill to disk (then
--   it is short of memory, the undersized check's case, and a smaller size would spill more)
-- investigate_if: WARN when small_query_pct >= warn_small_pct and the saving >= warn_saving_credits;
--   CRITICAL when small_query_pct >= crit_small_pct and the saving >= crit_saving_credits
-- actions: 1) ALTER WAREHOUSE ... SET WAREHOUSE_SIZE = suggested_size and watch p90 run time for a week
--   (config); 2) move the few heavy jobs (p90 columns) to their own warehouse so the shared one can
--   shrink (config)
-- next: none
-- caveats: the saving assumes small queries keep their run time one size down, usually true for
--   sub-second and few-GB queries but not guaranteed. Credits cover the whole window even if the size
--   changed in it. Snowpark-optimized warehouses bill more than the standard rate used here.
WITH __INCLUDE_warehouse_config__, __INCLUDE_sf_wh_size_rate__,
q AS (
  SELECT warehouse_name, UPPER(REPLACE(warehouse_size, '-', '')) AS size_key,
         COUNT(*) AS query_count,
         -- small = cheap enough that half the compute would still finish it quickly
         COUNT_IF(bytes_scanned < :small_scan_gb * POWER(1024, 3)
                  AND execution_time < :small_exec_s * 1000
                  AND bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage = 0) AS small_query_count,
         COUNT_IF(bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage > 0) AS spilling_query_count,
         COUNT_IF(bytes_spilled_to_remote_storage > 0) AS remote_spill_query_count,
         APPROX_PERCENTILE(execution_time / 1000, 0.5) AS p50_exec_s,
         APPROX_PERCENTILE(execution_time / 1000, 0.9) AS p90_exec_s,
         APPROX_PERCENTILE(bytes_scanned / POWER(1024, 3), 0.9) AS p90_scan_gb,
         MAX(bytes_scanned) / POWER(1024, 3) AS max_scan_gb
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL AND execution_status = 'SUCCESS' AND execution_time > 0
  GROUP BY 1, 2
),
m AS (
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_type, c.warehouse_size,
         CAST(c.max_clusters AS INTEGER) AS max_clusters, c.credits_per_hour, r.credits_per_hour AS size_rate,
         r.smaller_size,
         COALESCE(q.query_count, 0) AS query_count, COALESCE(q.small_query_count, 0) AS small_query_count,
         COALESCE(q.spilling_query_count, 0) AS spilling_query_count,
         COALESCE(q.remote_spill_query_count, 0) AS remote_spill_query_count,
         q.p50_exec_s, q.p90_exec_s, q.p90_scan_gb, q.max_scan_gb,
         COALESCE(m.compute_credits, 0) AS compute_credits,
         -- credits at the current size: the warehouse may have been resized inside the window, so the
         -- window's credits are split by the share of its statements that ran at this size
         COALESCE(m.compute_credits, 0) * COALESCE(q.query_count, 0) / NULLIF(qa.all_queries, 0) AS current_size_credits,
         100 * q.small_query_count / NULLIF(q.query_count, 0) AS small_query_pct,
         100 * q.spilling_query_count / NULLIF(q.query_count, 0) AS spilling_query_pct
  FROM warehouse_config c
  LEFT JOIN sf_wh_size_rate r ON r.size_key = UPPER(REPLACE(c.warehouse_size, '-', ''))
  LEFT JOIN q ON q.warehouse_name = c.warehouse_name AND q.size_key = r.size_key
  LEFT JOIN (SELECT warehouse_name, SUM(query_count) AS all_queries FROM q GROUP BY 1) qa
    ON qa.warehouse_name = c.warehouse_name
  LEFT JOIN m ON m.warehouse_name = c.warehouse_name
),
sp AS (
  -- short of memory: a smaller size would spill more, so there is no size-down saving
  SELECT j.*,
         CASE WHEN remote_spill_query_count > 0 THEN 'remote spill in ' || remote_spill_query_count || ' queries'
              WHEN spilling_query_pct >= :max_spilling_pct THEN ROUND(spilling_query_pct, 1) || '% of queries spill to disk'
         END AS spill_reason
  FROM j
),
s AS (
  SELECT sp.*,
         -- one size down halves the hourly rate (every generation doubles per size); never more than
         -- the warehouse's own compute credits in the window
         IFF(size_rate IS NULL OR credits_per_hour IS NULL, NULL,
             IFF(size_rate >= :min_credits_per_hour AND spill_reason IS NULL,
                 LEAST(COALESCE(current_size_credits, 0) / 2, compute_credits), 0)) AS est_saving_credits
  FROM sp
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_type, warehouse_size, max_clusters, credits_per_hour,
       query_count, small_query_count, small_query_pct, spilling_query_count, remote_spill_query_count,
       spill_reason,
       p50_exec_s, p90_exec_s, p90_scan_gb, max_scan_gb,
       compute_credits, compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       IFF(size_rate >= :min_credits_per_hour AND spill_reason IS NULL AND credits_per_hour IS NOT NULL, smaller_size, NULL) AS suggested_size,
       est_saving_credits, est_saving_credits * __CREDIT_PRICE__ AS est_saving_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       -- adaptive warehouses (credits_per_hour NULL) have no fixed rate to size down from
       CASE WHEN size_rate IS NULL OR credits_per_hour IS NULL THEN 'unknown_size'
            WHEN query_count < :min_queries THEN 'too_few_queries' END AS not_assessed_reason,
       CASE
         WHEN size_rate IS NULL OR credits_per_hour IS NULL OR query_count < :min_queries THEN 'NOT_ASSESSED'
         WHEN size_rate < :min_credits_per_hour OR spill_reason IS NOT NULL THEN 'OK'
         WHEN small_query_pct >= :crit_small_pct AND est_saving_credits >= :crit_saving_credits THEN 'CRITICAL'
         WHEN small_query_pct >= :warn_small_pct AND est_saving_credits >= :warn_saving_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_saving_credits DESC NULLS LAST, warehouse_name
