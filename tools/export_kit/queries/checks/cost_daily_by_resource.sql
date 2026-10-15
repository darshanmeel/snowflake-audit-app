-- query_id: cost_daily_by_resource
-- title: Daily credits and dollars per warehouse, serverless task and Snowpipe
-- domain: cost   tier: standard
-- entity: resources = resource_key
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- empty_if: role_cannot_see, no_activity
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :top_n (default 100) resources: per type, how many with the most credits in the window keep
--   their own rows before the rest are pooled
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Confirm that one warehouse's days add up to its
--   usd_list in cost_chargeback_by_warehouse for the same window.
-- read_this: One row = one day's credits for one resource: a warehouse, a serverless task or a pipe
--   (resource_type). resource_key is the type and the resource's id; the name is in warehouse_name,
--   task_full_name or pipe_name. Per type, the :top_n resources with the most credits in the window
--   keep their own rows; the rest are pooled per type and day into one is_other row, where
--   pooled_count is how many of them had usage that day. usd_list is credits at the effective $
--   per credit; billed_hours counts the hours a warehouse billed. A day with no row for a resource is a real $0 day, so average over the
--   window's days, not over the rows. Use it to compare a resource's average day before and after a
--   change.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory, nothing to act on
-- next: cost_chargeback_by_warehouse
-- caveats: The three types never overlap: a warehouse row is its compute plus billed cloud services
--   (the daily 10% adjustment is taken off), and tasks or pipes that run on a warehouse are in that
--   warehouse's rows, not their own. Serverless features other than tasks and Snowpipe are not here.
--   Days are UTC. An hour that spans midnight counts on the day it started. PIPE_USAGE_HISTORY rows
--   with no pipe id are external and directory table auto-refresh and Snowpipe Streaming, not a pipe:
--   they read pipe:none, named (auto-refresh or Streaming).
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
wh AS (
  SELECT 'warehouse' AS resource_type, TO_VARCHAR(w.warehouse_id) AS rid, MAX(w.warehouse_name) AS rname,
         DATE(w.start_time) AS usage_date,
         SUM(w.credits_used_compute + COALESCE(w.credits_used_cloud_services, 0) * COALESCE(r.billed_ratio, 1)) AS credits,
         COUNT_IF(w.credits_used > 0) AS billed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY w
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(w.start_time)
  WHERE w.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND w.start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 4
),
tk AS (
  SELECT 'task' AS resource_type, TO_VARCHAR(task_id) AS rid,
         MAX(database_name || '.' || schema_name || '.' || task_name) AS rname,
         DATE(start_time) AS usage_date, SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) AS credits,
         CAST(NULL AS NUMBER) AS billed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1, 2, 4
),
pp AS (
  SELECT 'pipe' AS resource_type, TO_VARCHAR(pipe_id) AS rid,
         IFF(MAX(pipe_id) IS NULL, '(auto-refresh or Streaming)', MAX(pipe_name)) AS rname,
         DATE(start_time) AS usage_date, SUM(credits_used) AS credits, CAST(NULL AS NUMBER) AS billed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
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
