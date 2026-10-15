-- query_id: sf_load_copy_listing_overhead
-- shims: QUERY_HISTORY
-- reads: INFORMATION_SCHEMA table functions QUERY_HISTORY
-- fallback_note: queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures
WITH cp AS (
  SELECT warehouse_id, warehouse_name, user_name, COALESCE(query_parameterized_hash, query_hash) AS shape,
         list_external_files_time, total_elapsed_time, execution_time, credits_used_cloud_services
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND query_type = 'COPY' AND COALESCE(list_external_files_time, 0) > 0
),
g AS (
  SELECT MAX(TO_VARCHAR(warehouse_id)) AS warehouse_id, warehouse_name, user_name, COUNT(DISTINCT shape) AS copy_shapes,
         COUNT(*) AS copies,
         SUM(list_external_files_time) / 60000 AS list_minutes,
         MEDIAN(list_external_files_time) / 1000 AS median_list_s,
         SUM(total_elapsed_time) / 60000 AS elapsed_minutes,
         SUM(execution_time) / 60000 AS exec_minutes,
         SUM(credits_used_cloud_services) AS cloud_services_credits
  FROM cp
  GROUP BY 2, 3
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, COALESCE(warehouse_id, warehouse_name) AS warehouse_id,
       warehouse_name, user_name, copy_shapes, copies,
       ROUND(list_minutes, 1) AS list_minutes, ROUND(median_list_s, 1) AS median_list_s,
       ROUND(elapsed_minutes, 1) AS elapsed_minutes, ROUND(exec_minutes, 1) AS exec_minutes,
       ROUND(100 * list_minutes / NULLIF(elapsed_minutes, 0), 1) AS list_pct,
       cloud_services_credits,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN list_minutes < :min_list_minutes THEN 'OK'
         WHEN 100 * list_minutes / NULLIF(elapsed_minutes, 0) >= :crit_list_pct THEN 'CRITICAL'
         WHEN 100 * list_minutes / NULLIF(elapsed_minutes, 0) >= :warn_list_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM g
ORDER BY list_minutes DESC, warehouse_name
