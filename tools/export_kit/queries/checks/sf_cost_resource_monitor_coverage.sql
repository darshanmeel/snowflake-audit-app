-- query_id: sf_cost_resource_monitor_coverage
-- title: Warehouse spend without a resource monitor cap
-- domain: cost   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- pre: SHOW RESOURCE MONITORS
-- reads: SHOW WAREHOUSES, SHOW RESOURCE MONITORS, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see); MONITOR on the resource monitors (SHOW lists only those
--   the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_spend_credits (default 20) spend credits: least a row needs before it can flag;
--   :warn_used_pct (default 80) used pct: at or above this the row reads WARN; :crit_used_pct (default
--   100) used pct: at or above this the row reads CRITICAL; :crit_uncapped_share_pct (default 50)
--   uncapped share pct: at or above this share of warehouse spend with no suspending monitor, an
--   uncapped warehouse reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. monitor_name is the monitor that caps it: its own, else the
--   account-level monitor (monitor_level). has_suspend = the monitor suspends the warehouse at some
--   quota %, not only notifies. used_pct = the monitor's used credits / quota in its current cycle.
--   uncapped_share_pct = the share of all warehouse credits in the window on warehouses no monitor
--   suspends (the same on every row).
-- healthy: status = OK when every warehouse that spends is under a monitor that suspends it, and no
--   monitor is near its quota.
-- investigate_if: WARN when a warehouse spending >= min_spend_credits in the window has only a
--   notify-only monitor, or its monitor is >= warn_used_pct used; CRITICAL when it has no monitor at
--   all, or its monitor is >= crit_used_pct used (it is or will be suspended), or it is uncapped while
--   uncapped_share_pct >= crit_uncapped_share_pct (most of the spend has no cap).
-- actions: 1) agree a monthly credit quota per warehouse with its owner (free); 2) CREATE RESOURCE
--   MONITOR ... TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND and ALTER WAREHOUSE ... SET
--   RESOURCE_MONITOR, plus one account-level monitor as a backstop (config); 3) raise the quota of a
--   monitor about to suspend business-critical work (spend).
-- next: none
-- not_assessed_reasons: not_in_show_warehouses: the warehouse billed in the window but SHOW WAREHOUSES does
--   not list it (dropped, or the role cannot see it: grant MONITOR); monitor_not_visible: the warehouse
--   names a monitor that SHOW RESOURCE MONITORS does not list for this role
-- caveats: SHOW RESOURCE MONITORS lists only monitors the role can see (ACCOUNTADMIN sees all), so an
--   account-level monitor the role cannot see reads as no monitor.
--   Monitors cap warehouses only; serverless, storage and AI credits are not capped by them.
WITH -- Share of each day's cloud services credits that is billed once the daily 10% adjustment is taken off.
-- Warehouse rows carry cloud services before that adjustment, so a billed figure is
-- credits_used_compute + credits_used_cloud_services * billed_ratio. A day with no daily row reads 1.
sf_cs_ratio AS (
  SELECT usage_date,
         GREATEST(SUM(credits_used_cloud_services + credits_adjustment_cloud_services), 0)
           / NULLIF(SUM(credits_used_cloud_services), 0) AS billed_ratio
  FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
  -- the warehouse service's own adjustment: other services' cloud services are adjusted on their own rows
  WHERE service_type = 'WAREHOUSE_METERING' AND usage_date >= DATEADD(day, -2 * :period_days - 1, __AS_OF_DATE__) AND usage_date < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY usage_date
),
wh AS (
  SELECT w."name" AS warehouse_name,
         NULLIF(NULLIF(TO_VARCHAR(w."resource_monitor"), 'null'), '') AS own_monitor
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2))) w
),
rm AS (
  SELECT m."name" AS monitor_name, UPPER(TO_VARCHAR(m."level")) AS monitor_level,
         TO_VARCHAR(m."frequency") AS frequency,
         TRY_TO_DOUBLE(TO_VARCHAR(m."credit_quota")) AS credit_quota,
         TRY_TO_DOUBLE(TO_VARCHAR(m."used_credits")) AS used_credits,
         TO_VARCHAR(m."notify_at") AS notify_at,
         TO_VARCHAR(m."suspend_at") AS suspend_at,
         TO_VARCHAR(m."suspend_immediately_at") AS suspend_immediately_at
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1))) m
),
acct AS (
  SELECT monitor_name FROM rm WHERE monitor_level = 'ACCOUNT' LIMIT 1
),
u AS (
  SELECT warehouse_name, MAX(TO_VARCHAR(warehouse_id)) AS warehouse_id, SUM((credits_used_compute + credits_used_cloud_services * COALESCE(r.billed_ratio, 1))) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  LEFT JOIN sf_cs_ratio r ON r.usage_date = DATE(start_time)
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    -- CLOUD_SERVICES_ONLY is a billing pseudo-warehouse: SHOW never lists it and no monitor can be set on it
    AND warehouse_name <> 'CLOUD_SERVICES_ONLY'
  GROUP BY warehouse_name
),
j AS (
  -- Rows come from billing, so a warehouse the role cannot SHOW is listed (as not assessed), not dropped.
  SELECT COALESCE(u.warehouse_name, wh.warehouse_name) AS warehouse_name,
         COALESCE(u.warehouse_id, wh.warehouse_name) AS warehouse_id,
         COALESCE(u.credits, 0) AS credits, wh.warehouse_name IS NOT NULL AS in_show, wh.own_monitor,
         COALESCE(wh.own_monitor, acct.monitor_name) AS monitor_name,
         IFF(wh.own_monitor IS NOT NULL, 'WAREHOUSE', IFF(acct.monitor_name IS NOT NULL, 'ACCOUNT', NULL)) AS monitor_level
  FROM u
  FULL OUTER JOIN wh ON wh.warehouse_name = u.warehouse_name
  LEFT JOIN acct ON TRUE
),
s AS (
  SELECT j.*, rm.monitor_name IS NOT NULL AS monitor_seen, rm.frequency, rm.credit_quota, rm.used_credits, rm.notify_at, rm.suspend_at,
         rm.suspend_immediately_at,
         (NULLIF(NULLIF(rm.suspend_at, 'null'), '') IS NOT NULL
          OR NULLIF(NULLIF(rm.suspend_immediately_at, 'null'), '') IS NOT NULL) AS has_suspend,
         100 * rm.used_credits / NULLIF(rm.credit_quota, 0) AS used_pct
  FROM j LEFT JOIN rm ON rm.monitor_name = j.monitor_name
),
sh AS (
  -- judged warehouses only: one the role cannot see is neither capped nor uncapped
  SELECT s.*,
         100 * SUM(IFF(in_show AND NOT COALESCE(has_suspend, FALSE), credits, 0)) OVER ()
           / NULLIF(SUM(IFF(in_show, credits, 0)) OVER (), 0) AS uncapped_share_pct
  FROM s
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_name, warehouse_id,
       credits AS window_credits, monitor_name, monitor_level, frequency, credit_quota,
       used_credits, used_pct, notify_at, suspend_at, suspend_immediately_at,
       COALESCE(has_suspend, FALSE) AS has_suspend, uncapped_share_pct,
       credits * __CREDIT_PRICE__ AS est_window_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN NOT in_show THEN 'not_in_show_warehouses'
            WHEN monitor_name IS NOT NULL AND NOT monitor_seen THEN 'monitor_not_visible' END AS not_assessed_reason,
       CASE
         WHEN NOT in_show OR (monitor_name IS NOT NULL AND NOT monitor_seen) THEN 'NOT_ASSESSED'
         WHEN used_pct >= :crit_used_pct THEN 'CRITICAL'
         WHEN credits >= :min_spend_credits AND monitor_name IS NULL THEN 'CRITICAL'
         WHEN credits >= :min_spend_credits AND NOT COALESCE(has_suspend, FALSE)
              AND uncapped_share_pct >= :crit_uncapped_share_pct THEN 'CRITICAL'
         WHEN used_pct >= :warn_used_pct THEN 'WARN'
         WHEN credits >= :min_spend_credits AND NOT COALESCE(has_suspend, FALSE) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM sh
ORDER BY window_credits DESC
