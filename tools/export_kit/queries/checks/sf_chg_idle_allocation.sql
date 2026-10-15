-- query_id: sf_chg_idle_allocation
-- title: Fully loaded cost per user, idle and cloud services shared back
-- domain: cost   tier: standard
-- money: est_loaded_usd_list
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_uplift_pct (default 50) uplift pct: at or above this the row reads WARN;
--   :crit_uplift_pct (default 150) uplift pct: at or above this the row reads CRITICAL; :min_loaded_usd
--   (default 100) loaded usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user, plus '(unallocated idle)' for warehouses that ran no attributed query.
--   direct_credits = exact attributed query credits; idle_credits_allocated = each warehouse's
--   unattributed compute (idle, auto-suspend tails, queries under about 100 ms) shared among its users
--   in proportion to their direct credits on it; cloud_services_billed_credits = the user's cloud
--   services credits scaled by the account's billed share after the daily 10% adjustment.
--   loaded_credits adds the three; uplift_pct = how much the fully loaded cost exceeds direct cost. The
--   user rows plus the unallocated row add up to warehouse compute plus billed cloud services.
-- healthy: status = OK when a user's fully loaded cost is not much above what their queries used.
-- investigate_if: WARN when uplift_pct >= warn_uplift_pct and loaded cost >= min_loaded_usd; CRITICAL
--   at crit_uplift_pct. A high uplift means the user runs on warehouses that mostly sit idle, or drives
--   metadata-heavy work.
-- actions: 1) look at the warehouses in main_warehouse_name for idle time
--   (sf_cost_warehouse_idle_credits_daily) (free); 2) lower auto-suspend or move the user to a busier
--   shared warehouse (config); 3) consolidate low-use warehouses (spend).
-- next: none
-- caveats: adaptive warehouses (no query-time split) and hours newer than the 8 h attribution lag are left out of both sides, so they never read as idle; the proportional split is one convention (Snowflake itself does not attribute idle). The
--   cloud services billed share is account-wide. Query acceleration and serverless feature
--   credits are billed as their own services and are not in the split (query_acceleration_credits is
--   shown apart).
--   Attribution lags up to 8 hours.
WITH qa AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name, COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)') AS user_name,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())
  GROUP BY TO_VARCHAR(warehouse_id), COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)')
),
wh AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_used_compute, 0)) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id)
),
resid AS (
  SELECT wh.warehouse_id, wh.warehouse_name,
         GREATEST(wh.compute_credits - COALESCE(x.credits, 0), 0) AS idle_credits, x.credits AS attributed
  FROM wh
  LEFT JOIN (SELECT warehouse_id, SUM(credits) AS credits FROM qa GROUP BY warehouse_id) x
    ON x.warehouse_id = wh.warehouse_id
),
ua AS (
  SELECT qa.user_name, SUM(qa.credits) AS direct_credits,
         SUM(r.idle_credits * qa.credits / NULLIF(r.attributed, 0)) AS idle_alloc,
         SUM(qa.qas_credits) AS qas_credits,
         MAX_BY(qa.warehouse_name, qa.credits) AS main_warehouse_name,
         COUNT(DISTINCT qa.warehouse_id) AS warehouses_used
  FROM qa
  LEFT JOIN resid r ON r.warehouse_id = qa.warehouse_id
  GROUP BY qa.user_name
),
cs AS (
  SELECT COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)') AS user_name, SUM(credits_used_cloud_services) AS cs_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)')
),
ratio AS (
  -- credits_adjustment_cloud_services is negative: the part covered by the free 10%.
  SELECT GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND usage_date < __AS_OF_DATE__
),
rows_ AS (
  SELECT COALESCE(ua.user_name, cs.user_name) AS user_name,
         IFF(COALESCE(ua.user_name, cs.user_name) = '(unknown user)', 'unknown_user', 'user') AS row_kind,
         ua.main_warehouse_name, ua.warehouses_used,
         COALESCE(ua.direct_credits, 0) AS direct_credits, ua.qas_credits AS qas_credits, COALESCE(ua.idle_alloc, 0) AS idle_credits_allocated,
         COALESCE(cs.cs_credits, 0) AS cloud_services_credits,
         COALESCE(cs.cs_credits, 0) * COALESCE(ratio.billed_ratio, 0) AS cloud_services_billed_credits
  FROM ua
  FULL OUTER JOIN cs ON cs.user_name = ua.user_name
  CROSS JOIN ratio
  UNION ALL
  SELECT '(unallocated idle)', 'unallocated',
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(warehouse_name), 0, 10), ', '), COUNT(*),
         0, NULL, SUM(idle_credits), 0, 0
  FROM resid
  WHERE COALESCE(attributed, 0) = 0 AND idle_credits > 0
  HAVING COUNT(*) > 0
),
s AS (
  SELECT r.*, direct_credits + idle_credits_allocated + cloud_services_billed_credits AS loaded_credits,
         100 * (idle_credits_allocated + cloud_services_billed_credits) / NULLIF(direct_credits, 0) AS uplift_pct
  FROM rows_ r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, row_kind,
       main_warehouse_name, warehouses_used, direct_credits, qas_credits AS query_acceleration_credits,
       idle_credits_allocated, cloud_services_credits, cloud_services_billed_credits, loaded_credits, uplift_pct,
       100 * loaded_credits / NULLIF(SUM(loaded_credits) OVER (), 0) AS share_of_loaded_pct,
       direct_credits * __CREDIT_PRICE__ AS est_direct_usd_list,
       loaded_credits * __CREDIT_PRICE__ AS est_loaded_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN loaded_credits * __CREDIT_PRICE__ < :min_loaded_usd THEN 'OK'
         WHEN row_kind = 'unallocated' THEN 'WARN'
         WHEN COALESCE(uplift_pct, 1e9) >= :crit_uplift_pct THEN 'CRITICAL'
         WHEN uplift_pct >= :warn_uplift_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
WHERE loaded_credits > 0
ORDER BY loaded_credits DESC
