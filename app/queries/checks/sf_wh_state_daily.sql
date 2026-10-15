-- query_id: sf_wh_state_daily
-- title: Warehouse hours per day: busy, idle and queued
-- domain: compute   tier: standard
-- entity: warehouses = warehouse_id
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- empty_if: role_cannot_see, no_activity
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: unknown_size: SHOW WAREHOUSES does not list the warehouse for this role, or it is
--   adaptive (no fixed hourly rate), so its credits cannot be turned into hours; no_query_attribution: no
--   billed hour of the day older than 8 h has a query-time split, so busy and idle cannot be told apart
-- read_this: One row = one warehouse on one UTC day it billed compute. up_hours = compute credits at the
--   warehouse's credits per hour for its current size and generation (cluster-hours, so a multi-cluster
--   day can pass 24). idle_hours is the part Snowflake attributes to no query (the same split as
--   sf_wh_idle_minutes); busy_hours = up_hours - idle_hours. queued_hours and provisioning_hours are
--   wall-clock hours of 5-minute intervals in which some query waited for a free slot (warehouse at
--   capacity) or for compute to start (WAREHOUSE_LOAD_HISTORY). est_compute_usd_list is the day's
--   compute spend: context, never added to idle waste.
-- healthy: n/a - inventory (the verdicts are sf_wh_idle_minutes and sf_wh_load_utilization)
-- investigate_if: n/a - inventory; days with idle hours above busy hours, or queued hours, repeat on the
--   same warehouse
-- actions: n/a - inventory, nothing to act on; see sf_wh_idle_minutes and sf_wh_load_utilization
-- next: sf_wh_idle_minutes, sf_wh_load_utilization
-- caveats: Hours are estimated from credits at the current size, so a day before a resize reads at the
--   new size. Hours newer than the 8 h attribution lag and adaptive warehouses have no idle split. Cloud
--   services credits are not in est_compute_usd_list. Queued hours overlap busy hours: they are a part of
--   the busy time, not added to it. ACCOUNT_USAGE lags up to 3 h.
WITH __INCLUDE_warehouse_config__,
m AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date,
         SUM(credits_used_compute) AS compute_credits,
         COUNT_IF(credits_used_compute > 0) AS metered_hours,
         -- Only hours older than the 8 h attribution lag with a non-NULL split count as idle evidence.
         SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL, credits_used_compute, 0)) AS attributed_compute_credits,
         SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_attributed_compute_queries, 0)) AS attributed_query_credits,
         COUNT_IF(credits_used_compute > 0 AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) AS attributed_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time)
  HAVING SUM(credits_used_compute) > 0
),
ld AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date,
         SUM(IFF(avg_running > 0, DATEDIFF(second, start_time, end_time), 0)) / 3600 AS running_hours,
         SUM(IFF(avg_queued_load > 0, DATEDIFF(second, start_time, end_time), 0)) / 3600 AS queued_hours,
         SUM(IFF(avg_queued_provisioning > 0, DATEDIFF(second, start_time, end_time), 0)) / 3600 AS provisioning_hours,
         SUM(avg_queued_load * DATEDIFF(second, start_time, end_time)) / 3600 AS queued_query_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time)
),
-- Outer, so a day with load but no metering row yet (lag) is kept.
j AS (
  SELECT COALESCE(m.warehouse_id, l.warehouse_id) AS warehouse_id,
         COALESCE(m.warehouse_name, l.warehouse_name) AS warehouse_name,
         COALESCE(m.usage_date, l.usage_date) AS usage_date,
         m.compute_credits, m.metered_hours, m.attributed_compute_credits, m.attributed_query_credits,
         COALESCE(m.attributed_hours, 0) AS attributed_hours,
         l.running_hours, l.queued_hours, l.provisioning_hours, l.queued_query_hours
  FROM m FULL OUTER JOIN ld l ON l.warehouse_id = m.warehouse_id AND l.usage_date = m.usage_date
),
s AS (
  SELECT j.*, c.warehouse_size, c.credits_per_hour,
         j.compute_credits / NULLIF(c.credits_per_hour, 0) AS up_hours,
         IFF(j.attributed_hours > 0, GREATEST(j.attributed_compute_credits - j.attributed_query_credits, 0), NULL)
           / NULLIF(c.credits_per_hour, 0) AS idle_hours
  FROM j LEFT JOIN warehouse_config c ON c.warehouse_name = j.warehouse_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, usage_date, warehouse_id, warehouse_name,
       warehouse_size, metered_hours, compute_credits,
       ROUND(up_hours, 3) AS up_hours,
       ROUND(GREATEST(up_hours - idle_hours, 0), 3) AS busy_hours,
       ROUND(idle_hours, 3) AS idle_hours,
       ROUND(COALESCE(queued_hours, 0), 3) AS queued_hours,
       ROUND(COALESCE(provisioning_hours, 0), 3) AS provisioning_hours,
       ROUND(queued_query_hours, 3) AS queued_query_hours,
       ROUND(running_hours, 3) AS running_hours,
       compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN compute_credits IS NULL THEN NULL
            WHEN credits_per_hour IS NULL THEN 'unknown_size'
            WHEN attributed_hours = 0 THEN 'no_query_attribution' END AS not_assessed_reason
FROM s
ORDER BY warehouse_id, usage_date
