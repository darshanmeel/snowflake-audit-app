-- windowed: yes
-- What each warehouse billed (compute plus billed cloud services), how much of it queries account for
-- (attributed) and how much ran with no query (idle: only hours old enough to be attributed and only
-- warehouses with a query-time split; adaptive warehouses are never counted idle).
WITH __INCLUDE_sf_cs_billed_ratio__,
w AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         SUM(credits_used_compute) AS compute_credits,
         SUM(credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1)) AS billed_credits,
         SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()),
                 credits_used_compute, 0)) AS attributable_compute,
         SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()),
                 credits_attributed_compute_queries, 0)) AS attributable_queries
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id)
),
a AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, SUM(credits_attributed_compute) AS attributed_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id)
)
SELECT :period_days AS window_days, w.warehouse_id, w.warehouse_name, w.compute_credits, w.billed_credits,
       COALESCE(a.attributed_credits, 0) AS attributed_credits,
       GREATEST(w.attributable_compute - w.attributable_queries, 0) AS idle_credits
FROM w LEFT JOIN a ON a.warehouse_id = w.warehouse_id
