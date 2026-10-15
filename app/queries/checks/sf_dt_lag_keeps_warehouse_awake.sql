-- query_id: sf_dt_lag_keeps_warehouse_awake
-- title: Dynamic tables whose refreshes keep a warehouse from suspending
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- money: est_idle_context_usd_list
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_credits (default 10) credits kept awake at or above which the row reads WARN;
--   :crit_credits (default 100) the same that reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse that ran dynamic-table refreshes in the window. Target lag is a
--   staleness goal, not an interval, but a short lag makes Snowflake refresh often: when the refreshes
--   come sooner than the warehouse's auto-suspend, it never gets to suspend. dts_sooner_than_suspend
--   counts the tables whose median gap between refreshes is at or under the auto-suspend. The gaps
--   between queries are replayed twice against the current auto-suspend (as in sf_wh_keepalive_pollers):
--   with every query, and without those tables' refreshes. dt_keepawake_hours is the extra up time, less
--   the refreshes'
--   own run time (that is work, not idle); dt_keepawake_credits prices it at the warehouse's credits per
--   hour and is capped at its idle credits. est_idle_context_usd_list is part of the idle $ of
--   sf_wh_idle_minutes, never added to it or to any waste total. top_dt_* name the dynamic table with
--   the most refreshes, its target lag and the median seconds between its refreshes.
-- healthy: status = OK when refreshes keep the warehouse up for less than warn_credits in the window
-- investigate_if: WARN when dt_keepawake_credits >= warn_credits; CRITICAL when >= crit_credits
-- actions: 1) raise TARGET_LAG above the auto-suspend plus a refresh's run time, or set DOWNSTREAM on
--   tables only other dynamic tables read (free); 2) give the lags of the tables on one warehouse the
--   same value so their refreshes run together (free); 3) move the refreshes to a warehouse that is up
--   for other work anyway, or give them their own X-Small with a 60 s auto-suspend (config)
-- next: sf_wh_idle_minutes, sf_dt_cost, sf_wh_keepalive_pollers
-- not_assessed_reasons: unknown_size: the warehouse's size or type has no fixed hourly rate (adaptive),
--   so the up time cannot be priced; auto_suspend_off: auto-suspend is off, so the setting keeps it up,
--   not the refreshes; no_query_attribution: the warehouse has no query attribution, so its idle credits
--   are unknown
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only) with window functions per
--   warehouse; only aggregates leave Snowflake. Refreshes are matched to their statements by query_id;
--   a refresh with no query (NO_DATA) does not use the warehouse. One cluster is assumed. Taking the
--   refreshes' own run time off makes the figure a floor. The refresh history lags up to 3 hours.
WITH __INCLUDE_warehouse_config__,
cfg AS (
  -- a setting under 60 s is replayed as 60 s, as in sf_wh_auto_suspend_tuning
  SELECT c.*, IFF(COALESCE(c.auto_stop_minutes, 0) = 0, NULL, GREATEST(c.auto_stop_minutes * 60, 60)) AS cur_s
  FROM warehouse_config c
),
dtr AS (
  SELECT query_id, MAX(database_name || '.' || schema_name || '.' || name) AS dt_full_name,
         MAX(target_lag_sec) AS target_lag_sec
  FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
  WHERE refresh_start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND refresh_start_time < __AS_OF_DATE__
    AND query_id IS NOT NULL
  GROUP BY 1
),
base AS (
  SELECT q.warehouse_name, q.start_time, q.end_time, q.execution_time, d.dt_full_name, d.target_lag_sec,
         d.query_id IS NOT NULL AS is_dt
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
  LEFT JOIN dtr d ON d.query_id = q.query_id
  WHERE q.start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND q.start_time < __AS_OF_DATE__
    AND q.warehouse_id IS NOT NULL AND q.execution_time > 0
),
gap AS (
  SELECT warehouse_name, dt_full_name, target_lag_sec,
         DATEDIFF(second, LAG(start_time) OVER (PARTITION BY warehouse_name, dt_full_name ORDER BY start_time), start_time) AS since_prev_s
  FROM base
  WHERE is_dt
),
per_dt AS (
  SELECT warehouse_name, dt_full_name, MAX(target_lag_sec) AS target_lag_sec, COUNT(*) AS refreshes,
         MEDIAN(since_prev_s) AS every_s
  FROM gap
  GROUP BY 1, 2
),
fast_dt AS (
  -- tables whose refreshes come sooner than the warehouse can suspend: only these keep it up
  SELECT p.warehouse_name, p.dt_full_name
  FROM per_dt p JOIN cfg c ON c.warehouse_name = p.warehouse_name
  WHERE c.cur_s IS NOT NULL AND p.every_s <= c.cur_s
),
tagged AS (
  SELECT b.warehouse_name, b.start_time, b.end_time, b.execution_time, fd.dt_full_name IS NOT NULL AS is_fast
  FROM base b
  LEFT JOIN fast_dt fd ON fd.warehouse_name = b.warehouse_name AND fd.dt_full_name = b.dt_full_name
  WHERE b.warehouse_name IN (SELECT warehouse_name FROM fast_dt)
),
q_all AS (
  SELECT warehouse_name, start_time, end_time,
         MAX(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time, end_time
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM tagged
),
q_rest AS (
  SELECT warehouse_name, start_time, end_time,
         MAX(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time, end_time
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM tagged
  WHERE NOT is_fast
),
-- up time = first start to last end, less the part of each gap past the auto-suspend
up_all AS (
  SELECT q.warehouse_name,
         DATEDIFF(millisecond, MIN(q.start_time), MAX(q.end_time)) / 1000
           - SUM(IFF(q.start_time > q.prev_end, GREATEST(DATEDIFF(millisecond, q.prev_end, q.start_time) / 1000 - c.cur_s, 0), 0)) AS up_s
  FROM q_all q JOIN cfg c ON c.warehouse_name = q.warehouse_name
  WHERE c.cur_s IS NOT NULL
  GROUP BY 1
),
up_rest AS (
  SELECT q.warehouse_name,
         DATEDIFF(millisecond, MIN(q.start_time), MAX(q.end_time)) / 1000
           - SUM(IFF(q.start_time > q.prev_end, GREATEST(DATEDIFF(millisecond, q.prev_end, q.start_time) / 1000 - c.cur_s, 0), 0)) AS up_s
  FROM q_rest q JOIN cfg c ON c.warehouse_name = q.warehouse_name
  WHERE c.cur_s IS NOT NULL
  GROUP BY 1
),
fast_exec AS (
  -- the fast refreshes' own run time is work, not idle
  SELECT warehouse_name, SUM(execution_time) / 1000 AS fast_exec_s FROM tagged WHERE is_fast GROUP BY 1
),
fast AS (
  SELECT warehouse_name, COUNT(*) AS dts_sooner_than_suspend FROM fast_dt GROUP BY 1
),
dt_sum AS (
  SELECT warehouse_name, COUNT(*) AS dt_refreshes, COUNT(DISTINCT dt_full_name) AS dynamic_tables,
         MIN(target_lag_sec) AS min_target_lag_s
  FROM base
  WHERE is_dt
  GROUP BY 1
),
top AS (
  SELECT warehouse_name, dt_full_name AS top_dt_full_name, target_lag_sec AS top_dt_target_lag_s,
         every_s AS top_dt_every_s, refreshes AS top_dt_refreshes
  FROM per_dt
  QUALIFY ROW_NUMBER() OVER (PARTITION BY warehouse_name ORDER BY refreshes DESC, dt_full_name) = 1
),
m AS (
  -- attribution is summed without COALESCE: NULL on adaptive warehouses means unknown, not zero
  SELECT warehouse_name, SUM(credits_used_compute) AS compute_credits,
         SUM(credits_used_compute) - SUM(credits_attributed_compute_queries) AS idle_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
r AS (
  SELECT c.warehouse_id, c.warehouse_name, c.warehouse_size, c.warehouse_type, c.credits_per_hour,
         CAST(c.auto_stop_minutes * 60 AS INTEGER) AS auto_suspend_s, c.cur_s,
         s.dt_refreshes, s.dynamic_tables, s.min_target_lag_s, COALESCE(fs.dts_sooner_than_suspend, 0) AS dts_sooner_than_suspend,
         top.top_dt_full_name, top.top_dt_target_lag_s, top.top_dt_every_s, top.top_dt_refreshes,
         ua.up_s AS up_s_all, COALESCE(ur.up_s, 0) AS up_s_rest, m.compute_credits, m.idle_credits,
         GREATEST(COALESCE(ua.up_s, 0) - COALESCE(ur.up_s, 0) - COALESCE(fe.fast_exec_s, 0), 0) AS keepawake_s_raw
  FROM dt_sum s
  JOIN cfg c ON c.warehouse_name = s.warehouse_name
  LEFT JOIN fast fs ON fs.warehouse_name = s.warehouse_name
  LEFT JOIN top ON top.warehouse_name = s.warehouse_name
  LEFT JOIN up_all ua ON ua.warehouse_name = s.warehouse_name
  LEFT JOIN up_rest ur ON ur.warehouse_name = s.warehouse_name
  LEFT JOIN fast_exec fe ON fe.warehouse_name = s.warehouse_name
  LEFT JOIN m ON m.warehouse_name = s.warehouse_name
),
f AS (
  -- part of the idle credits, so never more than them
  SELECT r.*, LEAST(keepawake_s_raw / 3600 * credits_per_hour, GREATEST(COALESCE(idle_credits, 0), 0)) AS dt_keepawake_credits
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size,
       COALESCE(warehouse_type, 'STANDARD') AS warehouse_type, credits_per_hour, auto_suspend_s,
       dynamic_tables, dt_refreshes, ROUND(dt_refreshes / :period_days, 1) AS dt_refreshes_per_day,
       dts_sooner_than_suspend, min_target_lag_s,
       top_dt_full_name, top_dt_target_lag_s, ROUND(top_dt_every_s, 0) AS top_dt_every_s, top_dt_refreshes,
       ROUND(up_s_all / 3600, 1) AS up_hours_now, ROUND(up_s_rest / 3600, 1) AS up_hours_without_fast_refreshes,
       ROUND(dt_keepawake_credits / NULLIF(credits_per_hour, 0), 1) AS dt_keepawake_hours,
       idle_credits, dt_keepawake_credits,
       dt_keepawake_credits * __CREDIT_PRICE__ AS est_idle_context_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN credits_per_hour IS NULL THEN 'unknown_size'
            WHEN cur_s IS NULL THEN 'auto_suspend_off'
            WHEN compute_credits IS NOT NULL AND idle_credits IS NULL THEN 'no_query_attribution' END AS not_assessed_reason,
       CASE
         WHEN credits_per_hour IS NULL OR cur_s IS NULL OR (compute_credits IS NOT NULL AND idle_credits IS NULL) THEN 'NOT_ASSESSED'
         WHEN dt_keepawake_credits >= :crit_credits THEN 'CRITICAL'
         WHEN dt_keepawake_credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY dt_keepawake_credits DESC NULLS LAST, warehouse_name
