-- query_id: sf_ai_snowpark_container_services
-- title: Snowpark Container Services compute pool spend
-- domain: serving_ai   tier: standard
-- entity: compute pools = compute_pool_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_usd (default 50) spend usd: least a row needs before it can flag;
--   :warn_always_on_pct (default 90) always on pct: at or above this the row reads WARN;
--   :warn_increase_pct (default 50) increase pct: at or above this the row reads WARN;
--   :crit_increase_pct (default 150) increase pct: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one compute pool. active_hours = hours in the window with credits; always_on_pct
--   = active_hours / hours in the window (100 = the pool never suspended, e.g. GPU nodes kept up
--   overnight). current = the window, previous = the window before.
-- healthy: status = OK when a pool's spend is small, flat, and it suspends when not in use.
-- investigate_if: WARN when a pool spending >= min_spend_usd is new, grew >= warn_increase_pct, or is
--   up >= warn_always_on_pct of the time; CRITICAL when it grew >= crit_increase_pct.
-- actions: 1) check which services and jobs run on the always-on pools and whether they need to (free);
--   2) set AUTO_SUSPEND_SECS, lower MIN_NODES to 0-1, pick a smaller INSTANCE_FAMILY (config); 3) drop
--   unused pools and move batch work to jobs that end (spend).
-- next: none
-- caveats: a pool that serves live traffic may need to stay up; always-on is a lead, not a fault. Pool
--   storage and data transfer are billed elsewhere.
WITH p AS (
  SELECT compute_pool_name,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS cur_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), credits_used, 0)) AS prev_credits,
         COUNT(DISTINCT IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND credits_used > 0,
                            DATE_TRUNC('hour', start_time), NULL)) AS active_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
s AS (
  SELECT p.*, 100 * (cur_credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
         100 * active_hours / (24 * :period_days) AS always_on_pct,
         cur_credits * __CREDIT_PRICE__ AS cur_usd
  FROM p
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, compute_pool_name,
       active_hours, always_on_pct,
       cur_credits AS current_credits, prev_credits AS previous_credits, change_pct,
       cur_credits / NULLIF(active_hours, 0) AS credits_per_active_hour,
       cur_credits * __CREDIT_PRICE__ AS est_current_usd_list,
       prev_credits * __CREDIT_PRICE__ AS est_previous_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN cur_usd < :min_spend_usd THEN 'OK'
         WHEN prev_credits = 0 THEN 'WARN'
         WHEN change_pct >= :crit_increase_pct THEN 'CRITICAL'
         WHEN change_pct >= :warn_increase_pct OR always_on_pct >= :warn_always_on_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY current_credits DESC
