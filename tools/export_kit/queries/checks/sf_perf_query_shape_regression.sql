-- query_id: sf_perf_query_shape_regression
-- title: Statement shapes that got slower in the last week (same parameterized hash, longer run time)
-- domain: performance   tier: standard
-- entity: query shapes = warehouse_id, query_parameterized_hash
-- money: est_change_usd_list
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :lookback_days (default 30) days of history the check looks at, counted back from the
--   export date, the same in every window (a week has nothing to compare with); :recent_days (default 7) the last days compared with the days before them in the window;
--   :min_runs (default 5) successful runs a shape needs in both parts before it can flag;
--   :min_p50_seconds (default 10) p50 seconds: a shape under this in both parts reads OK;
--   :warn_growth_pct (default 50) growth pct of the p50 run time: at or above this the row reads WARN;
--   :crit_growth_pct (default 150) growth pct: at or above this the row reads CRITICAL
-- empty_if: role_cannot_see, no_activity, ingestion_lag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape on one warehouse, with successful runs in the last recent_days
--   and in the days before. A shape is QUERY_PARAMETERIZED_HASH: the same statement with different literals.
--   Run time is compile plus execution, so queueing and warehouse resume are left out; runs under 100 ms
--   (result cache, metadata) are left out too. p50 is the median run, base_p90_s the slow end of the
--   earlier days: a recent median inside that range is noise, not a slowdown. likely_cause compares the two parts: worse_pruning (a larger share of partitions scanned), more_data
--   (more bytes per run with the same pruning), spilling (more spilled bytes per run), compile (compile
--   time grew most) or plan (none of these: compare the query profiles). extra_credits are the recent
--   runs' attributed credits above what the same runs cost at the earlier credits per run: a change, not
--   waste, never added to waste or savings.
-- healthy: status = OK when the p50 run time grew less than warn_growth_pct, stays within the earlier
--   p90, or the shape is short.
-- investigate_if: WARN when the p50 run time grew >= warn_growth_pct and is above the earlier p90;
--   CRITICAL at crit_growth_pct.
-- actions: 1) open a recent and an older query id in Snowsight and compare the profiles (free); 2) for
--   worse_pruning, see sf_perf_table_pruning_regression for the table and check its load order or
--   clustering key (free); 3) for more_data or spilling, filter on new rows only, or size the warehouse
--   up for this job alone (config / spend)
-- next: sf_perf_table_pruning_regression (if likely_cause = worse_pruning), sf_task_duration_regression,
--   sf_query_remote_spill (if likely_cause = spilling)
-- caveats: QUERY_HISTORY is read once over the window and aggregated in Snowflake (a heavy view; keep
--   the window short). A shape a task runs is also judged per task in sf_task_duration_regression, which
--   counts queueing; neither has a $ to add. Attributed credits leave out idle time and queries under
--   about 100 ms, and are NULL on adaptive warehouses (extra_credits then reads NULL). The last days lag up
--   to 45 minutes (QUERY_HISTORY) and 8 hours (attribution).
WITH q AS (
  SELECT query_parameterized_hash, warehouse_id, warehouse_name, query_type, user_name,
         start_time >= DATEADD(day, -:recent_days, __AS_OF_DATE__) AS is_recent,
         (compilation_time + execution_time) / 1000 AS run_s, compilation_time / 1000 AS compile_s,
         bytes_scanned, partitions_scanned, partitions_total,
         bytes_spilled_to_local_storage + bytes_spilled_to_remote_storage AS spilled
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status = 'SUCCESS' AND warehouse_id IS NOT NULL AND query_parameterized_hash IS NOT NULL
    -- result-cache and metadata answers take under 100 ms: left out, so a cache hit rate does not read as a slowdown
    AND execution_time >= 100
),
g AS (
  SELECT query_parameterized_hash, warehouse_id,
         MAX(warehouse_name) AS warehouse_name, MODE(query_type) AS statement_type,
         MODE(user_name) AS top_user,
         COUNT_IF(NOT is_recent) AS base_runs, COUNT_IF(is_recent) AS recent_runs,
         MEDIAN(IFF(NOT is_recent, run_s, NULL)) AS base_p50_s, MEDIAN(IFF(is_recent, run_s, NULL)) AS recent_p50_s,
         APPROX_PERCENTILE(IFF(NOT is_recent, run_s, NULL), 0.9) AS base_p90_s,
         MEDIAN(IFF(NOT is_recent, compile_s, NULL)) AS base_compile_s, MEDIAN(IFF(is_recent, compile_s, NULL)) AS recent_compile_s,
         AVG(IFF(NOT is_recent, bytes_scanned, NULL)) / POWER(1024, 3) AS base_gb_per_run,
         AVG(IFF(is_recent, bytes_scanned, NULL)) / POWER(1024, 3) AS recent_gb_per_run,
         100 * SUM(IFF(NOT is_recent, partitions_scanned, 0)) / NULLIF(SUM(IFF(NOT is_recent, partitions_total, 0)), 0) AS base_scan_pct,
         100 * SUM(IFF(is_recent, partitions_scanned, 0)) / NULLIF(SUM(IFF(is_recent, partitions_total, 0)), 0) AS recent_scan_pct,
         AVG(IFF(NOT is_recent, spilled, NULL)) / POWER(1024, 3) AS base_spill_gb_per_run,
         AVG(IFF(is_recent, spilled, NULL)) / POWER(1024, 3) AS recent_spill_gb_per_run,
         SUM(IFF(is_recent, run_s, 0)) / 3600 AS recent_run_hours
  FROM q
  GROUP BY query_parameterized_hash, warehouse_id
  HAVING COUNT_IF(NOT is_recent) >= :min_runs AND COUNT_IF(is_recent) >= :min_runs
     AND GREATEST(MEDIAN(IFF(NOT is_recent, run_s, NULL)), MEDIAN(IFF(is_recent, run_s, NULL))) >= :min_p50_seconds
),
-- attribution by shape and part, summed in Snowflake (no per-query join)
a AS (
  SELECT query_parameterized_hash, warehouse_id,
         SUM(IFF(start_time < DATEADD(day, -:recent_days, __AS_OF_DATE__), credits_attributed_compute, 0)) AS base_credits,
         SUM(IFF(start_time >= DATEADD(day, -:recent_days, __AS_OF_DATE__), credits_attributed_compute, 0)) AS recent_credits,
         COUNT(credits_attributed_compute) AS attributed_rows
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:lookback_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_parameterized_hash IN (SELECT query_parameterized_hash FROM g)
  GROUP BY query_parameterized_hash, warehouse_id
),
s AS (
  SELECT g.*, a.base_credits, a.recent_credits,
         100 * (recent_p50_s - base_p50_s) / NULLIF(base_p50_s, 0) AS growth_pct,
         IFF(a.attributed_rows > 0,
             GREATEST(a.recent_credits - recent_runs * a.base_credits / NULLIF(base_runs, 0), 0), NULL) AS extra_credits
  FROM g
  LEFT JOIN a ON a.query_parameterized_hash = g.query_parameterized_hash AND a.warehouse_id = g.warehouse_id
),
c AS (
  SELECT s.*,
         CASE WHEN COALESCE(recent_scan_pct, 0) - COALESCE(base_scan_pct, 0) >= 15 THEN 'worse_pruning'
              WHEN recent_spill_gb_per_run > 1 AND recent_spill_gb_per_run >= 2 * COALESCE(base_spill_gb_per_run, 0) THEN 'spilling'
              WHEN recent_gb_per_run >= 1.5 * NULLIF(base_gb_per_run, 0) THEN 'more_data'
              WHEN recent_compile_s - base_compile_s >= 0.5 * (recent_p50_s - base_p50_s) AND recent_compile_s > base_compile_s THEN 'compile'
              ELSE 'plan' END AS likely_cause
  FROM s
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, TO_VARCHAR(warehouse_id) AS warehouse_id,
       warehouse_name, query_parameterized_hash, statement_type, top_user, base_runs, recent_runs,
       base_p50_s, base_p90_s, recent_p50_s, growth_pct, base_compile_s, recent_compile_s, base_gb_per_run, recent_gb_per_run,
       base_scan_pct, recent_scan_pct, base_spill_gb_per_run, recent_spill_gb_per_run, recent_run_hours,
       IFF(growth_pct >= :warn_growth_pct AND recent_p50_s > base_p90_s, likely_cause, NULL) AS likely_cause,
       recent_credits, extra_credits,
       extra_credits * __CREDIT_PRICE__ AS est_change_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN recent_p50_s <= base_p90_s THEN 'OK'
         WHEN growth_pct >= :crit_growth_pct THEN 'CRITICAL'
         WHEN growth_pct >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM c
QUALIFY ROW_NUMBER() OVER (ORDER BY growth_pct DESC NULLS LAST, recent_run_hours DESC) <= 500
ORDER BY growth_pct DESC NULLS LAST
