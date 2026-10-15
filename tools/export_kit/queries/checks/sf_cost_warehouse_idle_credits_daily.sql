-- query_id: sf_cost_warehouse_idle_credits_daily
-- title: Idle warehouse credits per day and hour
-- domain: cost   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_idle_usd (default 10) idle usd: at or above this the row reads WARN; :crit_idle_usd
--   (default 100) idle usd: at or above this the row reads CRITICAL; :warn_idle_pct (default 40) idle
--   pct: at or above this the row reads WARN
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse in one billed hour (UTC; day_of_week is ISO, 1 = Monday). status
--   and the day_* columns judge the whole warehouse day and repeat on its hour rows. idle_credits = the
--   hour's compute credits minus credits_attributed_compute_queries, Snowflake's own split of running time into query time and
--   idle time (auto-suspend tails, gaps between queries, extra idle clusters).
--   est_idle_context_usd_list is context, not waste: the warehouse's possible waste is counted once, in
--   sf_wh_idle_minutes, and this per-day view is never added to it.
-- healthy: status = OK when a day's idle spend is small or a small part of that warehouse's day.
-- investigate_if: WARN when a day's idle is >= warn_idle_usd, or >= warn_idle_pct of the day with at
--   least a tenth of that amount; CRITICAL when a day's idle is >= crit_idle_usd.
-- actions: 1) look for the days and warehouses that repeat, and for days with no business load such as
--   weekends (free); 2) lower AUTO_SUSPEND to 60 s, lower MIN_CLUSTER_COUNT, stop keep-alive pings
--   (config); 3) consolidate low-use warehouses into one (spend).
-- next: none
-- caveats: adaptive warehouses have no query-time split (NULL), so their days are not assessed. The split is hourly and allocated by Snowflake; a warehouse kept warm on purpose for cache
--   or latency shows as idle. ACCOUNT_USAGE lags up to 3 h.
WITH h AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id, MAX(warehouse_name) AS warehouse_name,
         DATE(start_time) AS usage_date, HOUR(start_time) AS hour_of_day, DAYOFWEEKISO(start_time) AS day_of_week,
         SUM(credits_used_compute) AS compute_credits,
         SUM(credits_attributed_compute_queries) AS query_credits,
         -- An hour newer than the 8 h attribution lag or with a NULL split (adaptive) is not idle evidence.
         BOOLOR_AGG(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) AS attributed
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY TO_VARCHAR(warehouse_id), DATE(start_time), HOUR(start_time), DAYOFWEEKISO(start_time)
  HAVING SUM(credits_used_compute) > 0
),
s AS (
  SELECT h.*, IFF(attributed, GREATEST(compute_credits - COALESCE(query_credits, 0), 0), NULL) AS idle_credits,
         IFF(attributed, compute_credits, 0) AS attributed_compute_credits
  FROM h
),
-- The status is judged on the whole warehouse day and repeated on its hour rows.
d AS (
  SELECT s.*,
         COUNT(*) OVER (PARTITION BY warehouse_id, usage_date) AS day_billed_hours,
         COUNT_IF(attributed) OVER (PARTITION BY warehouse_id, usage_date) AS day_attributed_hours,
         SUM(idle_credits) OVER (PARTITION BY warehouse_id, usage_date) AS day_idle_credits,
         SUM(attributed_compute_credits) OVER (PARTITION BY warehouse_id, usage_date) AS day_attributed_compute_credits
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, warehouse_id,
       usage_date, hour_of_day, day_of_week, 1 AS billed_hours, compute_credits, query_credits, idle_credits,
       100 * idle_credits / NULLIF(compute_credits, 0) AS idle_pct,
       day_billed_hours, day_idle_credits,
       100 * day_idle_credits / NULLIF(day_attributed_compute_credits, 0) AS day_idle_pct,
       compute_credits * __CREDIT_PRICE__ AS est_compute_usd_list,
       idle_credits * __CREDIT_PRICE__ AS est_idle_context_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN day_attributed_hours = 0 THEN 'no_query_attribution' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR day_attributed_hours = 0 THEN 'NOT_ASSESSED'
         WHEN day_idle_credits * __CREDIT_PRICE__ >= :crit_idle_usd THEN 'CRITICAL'
         WHEN day_idle_credits * __CREDIT_PRICE__ >= :warn_idle_usd THEN 'WARN'
         WHEN 100 * day_idle_credits / NULLIF(day_attributed_compute_credits, 0) >= :warn_idle_pct
              AND day_idle_credits * __CREDIT_PRICE__ >= :warn_idle_usd / 10 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM d
ORDER BY day_idle_credits DESC NULLS LAST, warehouse_id, usage_date, hour_of_day
