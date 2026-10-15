-- query_id: cost_daily_by_resource
-- shims: METERING_DAILY_HISTORY, WAREHOUSE_METERING_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule; warehouse credits for 6 months at most; adaptive warehouses left out; the warehouse name stands in for its id; no per-query attribution; serverless task credits for 6 months at most; no database or schema names, and the task name stands in for its id; pipe credits for the last 14 days only; the pipe name stands in for its id
-- needs: MONITOR USAGE
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM __SHIM_METERING_DAILY_HISTORY__
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
wh AS (
  SELECT 'warehouse' AS resource_type, TO_VARCHAR(w.warehouse_id) AS rid, MAX(w.warehouse_name) AS rname,
         DATE(w.start_time) AS usage_date,
         SUM(w.credits_used_compute + COALESCE(w.credits_used_cloud_services, 0) * COALESCE(r.billed_ratio, 1)) AS credits,
         COUNT_IF(w.credits_used > 0) AS billed_hours
  FROM __SHIM_WAREHOUSE_METERING_HISTORY__ w
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(w.start_time)
  WHERE w.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND w.start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 4
),
tk AS (
  SELECT 'task' AS resource_type, TO_VARCHAR(task_id) AS rid,
         MAX(database_name || '.' || schema_name || '.' || task_name) AS rname,
         DATE(start_time) AS usage_date, SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) AS credits,
         CAST(NULL AS NUMBER) AS billed_hours
  FROM __SHIM_SERVERLESS_TASK_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 4
),
pp AS (
  SELECT 'pipe' AS resource_type, TO_VARCHAR(pipe_id) AS rid,
         IFF(MAX(pipe_id) IS NULL, '(auto-refresh or Streaming)', MAX(pipe_name)) AS rname,
         DATE(start_time) AS usage_date, SUM(credits_used) AS credits, CAST(NULL AS NUMBER) AS billed_hours
  FROM __SHIM_PIPE_USAGE_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 4
),
daily AS (
  SELECT * FROM wh UNION ALL SELECT * FROM tk UNION ALL SELECT * FROM pp
),
ranked AS (
  SELECT t.*, DENSE_RANK() OVER (PARTITION BY resource_type ORDER BY total_credits DESC, rid) AS rk
  FROM (SELECT d.*, SUM(COALESCE(credits, 0)) OVER (PARTITION BY resource_type, rid) AS total_credits
        FROM daily d) t
),
kept AS (
  SELECT usage_date, resource_type,
         IFF(rk > :top_n, resource_type || ':' || 'other', resource_type || ':' || COALESCE(rid, 'none')) AS resource_key,
         IFF(rk > :top_n, NULL, rid) AS rid, IFF(rk > :top_n, NULL, rname) AS rname, credits, billed_hours
  FROM ranked
)
-- is_other comes from the grouped key: Snowflake rejects a derived flag that wraps the window column.
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, resource_type, resource_key,
       resource_key = resource_type || ':' || 'other' AS is_other, IFF(resource_key = resource_type || ':' || 'other', COUNT(*), NULL) AS pooled_count,
       IFF(resource_type = 'warehouse', MAX(rid), NULL) AS warehouse_id,
       IFF(resource_type = 'warehouse', MAX(rname), NULL) AS warehouse_name,
       IFF(resource_type = 'task', MAX(rid), NULL) AS task_id,
       IFF(resource_type = 'task', MAX(rname), NULL) AS task_full_name,
       IFF(resource_type = 'pipe', MAX(rid), NULL) AS pipe_id,
       IFF(resource_type = 'pipe', MAX(rname), NULL) AS pipe_name,
       ROUND(SUM(credits), 4) AS credits,
       ROUND(SUM(credits) * __CREDIT_PRICE__, 2) AS usd_list,
       IFF(resource_type = 'warehouse', SUM(billed_hours), NULL) AS billed_hours,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis
FROM kept
GROUP BY usage_date, resource_type, resource_key
ORDER BY usage_date DESC, resource_type, resource_key
