-- query_id: sf_cost_cloud_services_billed
-- shims: METERING_DAILY_HISTORY
-- reads: INFORMATION_SCHEMA table functions WAREHOUSE_METERING_HISTORY, AUTOMATIC_CLUSTERING_HISTORY, MATERIALIZED_VIEW_REFRESH_HISTORY, SEARCH_OPTIMIZATION_HISTORY, SERVERLESS_TASK_HISTORY, PIPE_USAGE_HISTORY, QUERY_ACCELERATION_HISTORY, REPLICATION_GROUP_USAGE_HISTORY, SERVERLESS_ALERT_HISTORY
-- fallback_note: warehouses and serverless features only (no AI, containers or other services); adaptive warehouses left out; pipes for the last 14 days; cloud services adjusted by the daily 10% rule
-- needs: MONITOR USAGE
WITH d AS (
  SELECT usage_date,
         -- the 10% allowance is read against the day's virtual warehouse compute only, not serverless
         SUM(IFF(service_type = 'WAREHOUSE_METERING', credits_used_compute, 0)) AS compute_credits,
         SUM(credits_used_cloud_services) AS cloud_services_credits,
         -SUM(credits_adjustment_cloud_services) AS adjustment_credits
  FROM __SHIM_METERING_DAILY_HISTORY__
  WHERE usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
  GROUP BY usage_date
),
s AS (
  SELECT d.*,
         GREATEST(cloud_services_credits - adjustment_credits, 0) AS billed_cs_credits,
         100 * cloud_services_credits / NULLIF(compute_credits, 0) AS ratio_pct
  FROM d
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date,
       compute_credits, cloud_services_credits, adjustment_credits,
       LEAST(cloud_services_credits, adjustment_credits) AS free_cloud_services_credits,
       billed_cs_credits AS billed_cloud_services_credits,
       CASE
         WHEN COALESCE(cloud_services_credits, 0) <= 0 THEN 'no cloud services'
         WHEN billed_cs_credits <= 0 THEN 'all free (within 10%)'
         WHEN COALESCE(adjustment_credits, 0) <= 0 THEN 'all billed (no adjustment)'
         ELSE 'part billed (above 10%)'
       END AS allowance_result,
       ratio_pct AS cloud_services_ratio_pct,
       billed_cs_credits * __CREDIT_PRICE__ AS est_billed_cloud_services_usd_list,
       SUM(billed_cs_credits) OVER () * __CREDIT_PRICE__ AS est_window_billed_cloud_services_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN billed_cs_credits * __CREDIT_PRICE__ >= :crit_daily_billed_usd THEN 'CRITICAL'
         WHEN billed_cs_credits * __CREDIT_PRICE__ >= :warn_daily_billed_usd THEN 'WARN'
         WHEN billed_cs_credits > 0 AND ratio_pct >= :warn_ratio_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY usage_date DESC
