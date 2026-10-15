-- query_id: sf_cost_query_attribution_by_user
-- title: Warehouse spend by user, with the idle remainder
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_share_pct (default 30) share pct: at or above this the row reads WARN; :crit_share_pct
--   (default 60) share pct: at or above this the row reads CRITICAL; :min_spend_usd (default 100) spend
--   usd: least a row needs before it can flag; :warn_idle_pct (default 30) idle pct: at or above this
--   the row reads WARN; :crit_idle_pct (default 50) idle pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one user, plus one '(warehouse idle)' row. attributed_credits are the exact
--   per-query compute credits Snowflake assigns to the user; query_acceleration_credits are billed as
--   their own service and are shown apart, never inside the split. share_of_warehouse_pct is the part
--   of all warehouse compute credits in the window, so user rows plus the idle row add up to 100. A
--   query with no user name reads '(unknown user)' on its own row, never dropped or merged.
-- healthy: status = OK when no single user dominates warehouse spend and idle time stays small.
-- investigate_if: WARN when a user is >= warn_share_pct of warehouse spend (and >= min_spend_usd), or
--   idle is >= warn_idle_pct; CRITICAL at crit_share_pct / crit_idle_pct.
-- actions: 1) ask the owner of the top user (often a service account or BI tool) what it runs and how
--   often (free); 2) give heavy users their own warehouse or query tag so cost is owned; shorten
--   auto-suspend where idle is high (config); 3) right-size the warehouses they use (spend).
-- next: none
-- caveats: adaptive warehouses (no query-time split) and hours newer than the 8 h attribution lag are left out of both sides, so they never read as idle; queries under about 100 ms have no attribution row; idle time is not attributed to anyone
--   (Snowflake's rule). Cloud services, query acceleration and serverless credits are outside this split.
WITH u AS (
  SELECT COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)') AS user_name,
         COUNT(*) AS queries,
         COUNT(DISTINCT warehouse_id) AS warehouses_used,
         SUM(credits_attributed_compute) AS credits,
         SUM(COALESCE(credits_used_query_acceleration, 0)) AS qas_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP())
  GROUP BY COALESCE(NULLIF(TRIM(user_name), ''), '(unknown user)')
),
wh AS (
  SELECT SUM(IFF(credits_attributed_compute_queries IS NOT NULL AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_used_compute, 0)) AS compute_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
),
rows_ AS (
  SELECT user_name, IFF(user_name = '(unknown user)', 'unknown_user', 'user') AS row_kind, queries,
         warehouses_used, credits, qas_credits FROM u
  UNION ALL
  SELECT '(warehouse idle)', 'idle', NULL, NULL,
         GREATEST(wh.compute_credits - (SELECT COALESCE(SUM(credits), 0) FROM u), 0), NULL
  FROM wh
),
s AS (
  SELECT r.*, 100 * r.credits / NULLIF(wh.compute_credits, 0) AS share_pct, wh.compute_credits
  FROM rows_ r CROSS JOIN wh
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, user_name, row_kind,
       queries, warehouses_used, credits AS attributed_credits, qas_credits AS query_acceleration_credits,
       share_pct AS share_of_warehouse_pct, compute_credits AS warehouse_compute_credits,
       credits * __CREDIT_PRICE__ AS est_attributed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN COALESCE(compute_credits, 0) = 0 THEN 'no_warehouse_compute' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR COALESCE(compute_credits, 0) = 0 THEN 'NOT_ASSESSED'
         WHEN credits * __CREDIT_PRICE__ < :min_spend_usd THEN 'OK'
         WHEN row_kind = 'idle' AND share_pct >= :crit_idle_pct THEN 'CRITICAL'
         WHEN row_kind = 'idle' AND share_pct >= :warn_idle_pct THEN 'WARN'
         WHEN row_kind IN ('user', 'unknown_user') AND share_pct >= :crit_share_pct THEN 'CRITICAL'
         WHEN row_kind IN ('user', 'unknown_user') AND share_pct >= :warn_share_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY attributed_credits DESC NULLS LAST
