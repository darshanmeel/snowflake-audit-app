-- query_id: query_cache_coldstart
-- title: Result-cache hit rate and IO-cache cold-start latency
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_io_cache_pct (default 50) byte-weighted read_io_cache_percent below which a
--   day+warehouse flags WARN, and the per-query low-cache threshold; :crit_io_cache_pct (default 20)
--   byte-weighted read_io_cache_percent below which it flags CRITICAL; :min_scanned_queries (default 10)
--   queries that scanned data on that day and warehouse before the cache share is judged
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a day + warehouse whose queries were checked for cache reuse. The column that
--   drives status is read_io_cache_percent_weighted_avg (a read_bytes-weighted average over statements
--   that actually scanned data) - not the plain, unweighted read_io_cache_percent_avg kept alongside it
--   for reference. waiting_for_compute_ms_sum (cumulative cold-start/provisioning wait) is a separate
--   signal. scanned_query_count is how many of query_count actually scanned bytes; a day with a low
--   weighted average and a high low_io_cache_count is spending compute re-reading data it should be
--   caching.
-- healthy: read_io_cache_percent_weighted_avg at/above :warn_io_cache_pct (field heuristic - tune
--   :warn_io_cache_pct for your account).
-- investigate_if: read_io_cache_percent_weighted_avg below :warn_io_cache_pct (WARN) or below
--   :crit_io_cache_pct (CRITICAL) - field heuristic.
-- actions: 1) re-run a representative query back-to-back to confirm it is actually cold rather than
--   just infrequently reused (free); 2) pin hot tables to a warehouse that stays warm between runs, or
--   extend the warehouse's auto-stop timeout to avoid cold starts between queries (config); 3) move
--   latency-sensitive workloads to a warehouse that never idles down, such as a dedicated always-on
--   warehouse (spend).
-- next: none
-- caveats: Snowflake version: IO cache = percentage_scanned_from_cache (warehouse local-disk cache,
--   0-1, shown as 0-100); cold start wait = queued_provisioning_time. A result-cache hit is
--   approximate: a successful SELECT that scanned no bytes and touched no partitions (also matches
--   metadata-only answers).
WITH q AS (
  SELECT DATE(start_time) AS day, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name,
         IFF(query_type = 'SELECT' AND execution_status = 'SUCCESS'
             AND COALESCE(bytes_scanned, 0) = 0 AND COALESCE(partitions_total, 0) = 0, 1, 0) AS is_hit,
         COALESCE(bytes_scanned, 0) AS read_bytes,
         100 * percentage_scanned_from_cache AS cache_pct,
         queued_provisioning_time, compilation_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL
),
agg AS (
  SELECT day, warehouse_id, MAX(warehouse_name) AS warehouse_name,
         COUNT(*) AS query_count,
         SUM(is_hit) AS result_cache_hit_count,
         -- the cache averages cover only queries that really scanned data
         COUNT_IF(read_bytes > 0 AND is_hit = 0) AS scanned_query_count,
         AVG(cache_pct) AS cache_pct_avg,
         SUM(IFF(read_bytes > 0 AND is_hit = 0, cache_pct * read_bytes, NULL)) AS weighted_num,
         SUM(IFF(read_bytes > 0 AND is_hit = 0, read_bytes, NULL)) AS weighted_den,
         COUNT_IF(read_bytes > 0 AND is_hit = 0 AND cache_pct < :warn_io_cache_pct) AS low_io_cache_count,
         SUM(queued_provisioning_time) AS waiting_for_compute_ms_sum,
         SUM(compilation_time) AS compilation_duration_ms_sum
  FROM q
  GROUP BY day, warehouse_id
)
SELECT :period_days AS window_days, day, __ACCOUNT_ID__ AS account_id, 'WAREHOUSE' AS compute_type,
       warehouse_id, warehouse_name, query_count, result_cache_hit_count, scanned_query_count,
       ROUND(cache_pct_avg, 1) AS read_io_cache_percent_avg,
       ROUND(weighted_num / NULLIF(weighted_den, 0), 1) AS read_io_cache_percent_weighted_avg,
       low_io_cache_count, waiting_for_compute_ms_sum, compilation_duration_ms_sum,
       CASE WHEN scanned_query_count = 0 THEN 'no_scanned_queries'
            WHEN scanned_query_count < :min_scanned_queries THEN 'too_few_scanned_queries' END AS not_assessed_reason,
       CASE
         WHEN scanned_query_count < GREATEST(:min_scanned_queries, 1) THEN 'NOT_ASSESSED'
         WHEN weighted_num / NULLIF(weighted_den, 0) < :crit_io_cache_pct THEN 'CRITICAL'
         WHEN weighted_num / NULLIF(weighted_den, 0) < :warn_io_cache_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM agg
ORDER BY read_io_cache_percent_weighted_avg ASC NULLS LAST
