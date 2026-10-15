-- query_id: sf_perf_high_frequency_tail_latency
-- title: High-frequency statements with a bad slow tail, queueing or throttling
-- domain: performance   tier: standard
-- entity: query shapes = warehouse, query_parameterized_hash
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.AGGREGATE_QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 7) days of history the check looks at, counted back from the export
--   date; :min_calls (default 10000) calls: least a statement shape needs to be listed;
--   :warn_p99_ms (default 5000) p99 elapsed ms: at or above this the row reads WARN; :crit_p99_ms
--   (default 30000) p99 elapsed ms: at or above this the row reads CRITICAL; :warn_queued_pct
--   (default 10) queued pct of elapsed time: at or above this the row reads WARN; :crit_queued_pct
--   (default 30) queued pct: at or above this the row reads CRITICAL; :crit_throttled_pct (default 1)
--   throttled pct of calls: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse + one statement shape (parameterized hash) called at least
--   min_calls times. p99_elapsed_ms is the calls-weighted mean of the per-minute p99 values (percentiles
--   are not summed) and max_p99_elapsed_ms is the worst minute. queued_pct is overload queueing over
--   total elapsed time; throttled_requests are hybrid table requests Snowflake throttled.
-- healthy: status = OK when the slow tail is short, queueing is small and nothing was throttled.
-- investigate_if: WARN when p99 is >= warn_p99_ms, queued_pct is >= warn_queued_pct or any hybrid table
--   request was throttled; CRITICAL when p99 >= crit_p99_ms, queued_pct >= crit_queued_pct or throttled
--   requests are >= crit_throttled_pct of calls.
-- actions: 1) find the slow minutes of the shape and what else ran then (free); 2) give the shape its
--   own warehouse or raise max clusters for the queueing (config); 3) resize or move the hot table to
--   a hybrid-table-friendly design (spend).
-- next: none
-- empty_if: no_activity, view_missing, ingestion_lag
-- caveats: the view holds one row per minute for repeated statements, mostly Unistore and API
--   workloads, so most accounts show little. The weighted p99 is an approximation. Cloud services
--   credits are shown as raw credits, not priced. Statement text and error messages are never read;
--   only the error count is.
WITH a AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, query_parameterized_hash,
         MAX(warehouse_name) AS warehouse_name,
         SUM(calls) AS calls,
         SUM(total_elapsed_time:sum::NUMBER) AS elapsed_ms,
         SUM(total_elapsed_time:p99::NUMBER * calls) AS p99_weighted_ms,
         MAX(total_elapsed_time:p99::NUMBER) AS max_p99_ms,
         SUM(queued_overload_time:sum::NUMBER) AS queued_ms,
         SUM(credits_used_cloud_services:sum::FLOAT) AS cs_credits,
         SUM(COALESCE(hybrid_table_requests_throttled_count, 0)) AS throttled_requests
  FROM SNOWFLAKE.ACCOUNT_USAGE.AGGREGATE_QUERY_HISTORY
  WHERE interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND interval_start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), query_parameterized_hash
  HAVING SUM(calls) >= :min_calls
),
e AS (
  SELECT TO_VARCHAR(q.warehouse_id) AS warehouse_id, q.query_parameterized_hash,
         SUM(f.value:count::NUMBER) AS error_count
  FROM SNOWFLAKE.ACCOUNT_USAGE.AGGREGATE_QUERY_HISTORY q,
       LATERAL FLATTEN(input => q.errors, outer => TRUE) f
  WHERE q.interval_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND q.interval_start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(q.warehouse_id), q.query_parameterized_hash
),
s AS (
  SELECT a.*, COALESCE(e.error_count, 0) AS error_count,
         a.elapsed_ms / NULLIF(a.calls, 0) AS avg_elapsed_ms,
         a.p99_weighted_ms / NULLIF(a.calls, 0) AS p99_elapsed_ms,
         100 * a.queued_ms / NULLIF(a.elapsed_ms, 0) AS queued_pct,
         100 * a.throttled_requests / NULLIF(a.calls, 0) AS throttled_pct
  FROM a
  LEFT JOIN e ON e.warehouse_id = a.warehouse_id AND e.query_parameterized_hash = a.query_parameterized_hash
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       COALESCE(warehouse_name, 'unknown') || ' (' || COALESCE(warehouse_id, 'unknown') || ')' AS warehouse,
       query_parameterized_hash, calls, ROUND(avg_elapsed_ms, 1) AS avg_elapsed_ms,
       ROUND(p99_elapsed_ms, 1) AS p99_elapsed_ms, max_p99_ms AS max_p99_elapsed_ms,
       ROUND(queued_pct, 2) AS queued_pct, throttled_requests, ROUND(throttled_pct, 3) AS throttled_pct,
       error_count, cs_credits AS cloud_services_credits,
       CASE
         WHEN p99_elapsed_ms >= :crit_p99_ms OR queued_pct >= :crit_queued_pct
              OR throttled_pct >= :crit_throttled_pct THEN 'CRITICAL'
         WHEN p99_elapsed_ms >= :warn_p99_ms OR queued_pct >= :warn_queued_pct
              OR throttled_requests > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY p99_elapsed_ms DESC NULLS LAST, calls DESC
