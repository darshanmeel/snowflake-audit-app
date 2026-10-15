-- query_id: overview_credits_by_service
-- shims: METERING_DAILY_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule
-- needs: MONITOR USAGE
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, service_type AS sku_name,
       service_type AS billing_origin_product, SUM(credits_billed) AS net_credits
FROM __SHIM_METERING_DAILY_HISTORY__
WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
GROUP BY service_type
ORDER BY net_credits DESC
