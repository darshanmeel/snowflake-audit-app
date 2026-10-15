-- query_id: overview_warehouse_vs_serverless
-- shims: METERING_DAILY_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule
-- needs: MONITOR USAGE
WITH m AS (
  SELECT SUM(IFF(service_type IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER'), 0, credits_billed)) AS serverless,
         SUM(IFF(service_type IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER'), credits_billed, 0)) AS classic,
         SUM(credits_billed) AS total
  FROM __SHIM_METERING_DAILY_HISTORY__
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       serverless AS serverless_net_credits, classic AS classic_net_credits,
       100 * serverless / NULLIF(total, 0) AS serverless_pct,
       total AS total_net_credits
FROM m
