-- query_id: sf_cost_cloud_services_drivers
-- shims: QUERY_HISTORY, METERING_DAILY_HISTORY
-- reads: INFORMATION_SCHEMA table functions QUERY_HISTORY, WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY
-- fallback_note: queries for the last 7 days at most, only those this role can see; no spill, partition or cache figures; warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule
-- needs: MONITOR USAGE
WITH q AS (
  SELECT COALESCE(warehouse_name, '(none)') AS warehouse_name,
         COALESCE(TO_VARCHAR(warehouse_id), '(none)') AS warehouse_id,
         user_name, query_type,
         COUNT(*) AS queries,
         SUM(credits_used_cloud_services) AS cs_credits,
         AVG(compilation_time) AS avg_compilation_ms
  FROM __SHIM_QUERY_HISTORY__
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND credits_used_cloud_services > 0
  GROUP BY 1, 2, 3, 4
),
acct AS (
  SELECT SUM(credits_used_cloud_services) AS cs_used,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0) AS cs_billed
  FROM __SHIM_METERING_DAILY_HISTORY__
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
s AS (
  SELECT q.*, acct.cs_billed,
         100 * q.cs_credits / NULLIF(SUM(q.cs_credits) OVER (), 0) AS share_pct,
         acct.cs_billed * q.cs_credits / NULLIF(SUM(q.cs_credits) OVER (), 0) AS billed_share_credits
  FROM q CROSS JOIN acct
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, warehouse_id,
       user_name, query_type, queries, cs_credits AS cloud_services_credits, avg_compilation_ms,
       share_pct AS share_of_cloud_services_pct,
       billed_share_credits AS billed_share_credits,
       billed_share_credits * __CREDIT_PRICE__ AS est_billed_share_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cs_billed <= 0 OR billed_share_credits * __CREDIT_PRICE__ < :min_driver_usd THEN 'OK'
         WHEN share_pct >= :crit_share_pct THEN 'CRITICAL'
         WHEN share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY cloud_services_credits DESC
