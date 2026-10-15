-- query_id: sf_query_compilation_heavy
-- shims: METERING_DAILY_HISTORY, QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY, QUERY_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule; queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
-- needs: MONITOR USAGE
WITH -- Share of the window's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- A per-query cloud services credit is before that adjustment, so a billed figure is credits * billed_ratio.
sf_cs_window AS (
  SELECT COALESCE(GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
                    / NULLIF(SUM(credits_used_cloud_services), 0), 1) AS billed_ratio
  FROM __SHIM_METERING_DAILY_HISTORY__
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
qh AS (
  SELECT query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name, user_name,
         query_type, start_time, compilation_time, total_elapsed_time, credits_used_cloud_services,
         LENGTH(query_text) AS text_length
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_parameterized_hash IS NOT NULL AND compilation_time > 0
),
g AS (
  SELECT query_parameterized_hash, MODE(warehouse_name) AS warehouse_name, MAX(warehouse_id) AS warehouse_id,
         MODE(query_type) AS query_type, MODE(user_name) AS main_user_name, COUNT(*) AS runs,
         SUM(compilation_time) / 3600000 AS compile_hours,
         AVG(compilation_time) / 1000 AS avg_compile_s,
         100 * SUM(compilation_time) / NULLIF(SUM(total_elapsed_time), 0) AS compile_pct,
         SUM(credits_used_cloud_services) AS cs_credits,
         MAX(text_length) AS max_text_length
  FROM qh
  GROUP BY 1
  HAVING COUNT(*) >= :min_runs
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       query_parameterized_hash, query_type, main_user_name, runs, compile_hours, avg_compile_s, compile_pct,
       max_text_length, cs_credits, cs_credits * w.billed_ratio AS billed_cs_credits,
       cs_credits * w.billed_ratio * __CREDIT_PRICE__ AS est_billed_cs_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN compile_hours >= :crit_compile_hours OR cs_credits >= :crit_cs_credits THEN 'CRITICAL'
         WHEN (compile_pct >= :warn_compile_pct AND compile_hours >= :min_compile_hours)
           OR cs_credits >= :warn_cs_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g CROSS JOIN sf_cs_window w
ORDER BY compile_hours DESC
