-- query_id: sf_wh_keepalive_pollers
-- title: Warehouses kept awake by tiny repeated polls
-- domain: compute   tier: standard
-- windowed: yes
-- money: est_idle_context_usd_list
-- entity: warehouses = warehouse_id
-- pre: SHOW WAREHOUSES
-- empty_if: role_cannot_see, no_activity
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY,
--   SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_runs_per_day (default 12) runs per day a repeated statement needs, on average, before it
--   counts as a poll; :max_exec_ms (default 1000) median run time in milliseconds at or under which a
--   repeated statement counts as a poll; :warn_credits (default 10) credits kept awake at or above which
--   the row reads WARN; :crit_credits (default 100) the same that reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one warehouse. A poll is one user's repeated statement shape (the same
--   query_parameterized_hash) that runs at least min_runs_per_day times a day on average, takes at most
--   max_exec_ms, and repeats sooner than the warehouse's auto-suspend, so each run arrives before the
--   warehouse can suspend. The gaps between queries are replayed twice against the current auto-suspend
--   (the same replay as sf_wh_auto_suspend_tuning): with every query, and without the polls.
--   keepalive_hours is the up time the polls add; keepalive_credits prices it at the warehouse's credits
--   per hour and is capped at its idle credits (compute minus the credits Snowflake attributes to
--   queries). est_idle_context_usd_list is part of the idle $ of sf_wh_idle_minutes, never added to it
--   or to any waste total. top_poll_* name the poll with the most runs: user, statement type, shape
--   hash (never its text), median run time and the median seconds between its runs.
-- healthy: status = OK when polls keep the warehouse up for less than warn_credits in the window
-- investigate_if: WARN when keepalive_credits >= warn_credits; CRITICAL when >= crit_credits
-- actions: 1) point health checks and connection keep-alives at a query that needs no warehouse
--   (SELECT CURRENT_TIMESTAMP(), or the client's own keep-alive setting) (free); 2) poll less often than
--   the auto-suspend, or move the poll to a serverless task or alert (config); 3) give polls their own
--   X-Small warehouse with a 60 s auto-suspend (config)
-- next: sf_wh_idle_minutes, sf_wh_auto_suspend_tuning
-- not_assessed_reasons: unknown_size: the warehouse's size or type has no fixed hourly rate (adaptive),
--   so the up time cannot be priced; auto_suspend_off: auto-suspend is off, so the setting keeps it up,
--   not the polls (see the auto-suspend settings); no_query_attribution: the warehouse has no query
--   attribution, so its idle credits are unknown
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), with window functions per
--   warehouse and per statement shape; only aggregates leave Snowflake. Only statements that ran on the
--   warehouse (execution_time > 0) count, so queries the cloud services layer answers alone are left
--   out. One cluster is assumed. A poll that is also real work (a dashboard tile refreshed every
--   minute) reads as a poll: check top_poll_user_name before stopping it.
WITH __INCLUDE_warehouse_config__,
cfg AS (
  -- a setting under 60 s is replayed as 60 s, as in sf_wh_auto_suspend_tuning
  SELECT c.*, IFF(COALESCE(c.auto_stop_minutes, 0) = 0, NULL, GREATEST(c.auto_stop_minutes * 60, 60)) AS cur_s
  FROM warehouse_config c
),
base AS (
  SELECT warehouse_name, user_name, query_type, start_time, end_time, execution_time,
         COALESCE(query_parameterized_hash, query_type) AS shape
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND warehouse_id IS NOT NULL AND execution_time > 0
),
cad AS (
  SELECT warehouse_name, user_name, shape, query_type, execution_time,
         DATEDIFF(millisecond, LAG(start_time) OVER (PARTITION BY warehouse_name, user_name, shape ORDER BY start_time),
                  start_time) / 1000 AS since_prev_s
  FROM base
),
grp AS (
  SELECT warehouse_name, user_name, shape, MAX(query_type) AS query_type, COUNT(*) AS runs,
         MEDIAN(execution_time) AS median_exec_ms, MEDIAN(since_prev_s) AS cadence_s
  FROM cad
  GROUP BY 1, 2, 3
),
pol AS (
  -- a poll repeats sooner than the warehouse can suspend
  SELECT g.*
  FROM grp g JOIN cfg c ON c.warehouse_name = g.warehouse_name
  WHERE g.runs >= :min_runs_per_day * :period_days AND g.median_exec_ms <= :max_exec_ms
    AND c.cur_s IS NOT NULL AND g.cadence_s <= c.cur_s
),
tagged AS (
  SELECT b.warehouse_name, b.start_time, b.end_time, p.shape IS NOT NULL AS is_poll
  FROM base b
  LEFT JOIN pol p ON p.warehouse_name = b.warehouse_name AND p.user_name = b.user_name AND p.shape = b.shape
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
  WHERE NOT is_poll
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
ps AS (
  SELECT warehouse_name, COUNT(*) AS poll_shapes, SUM(runs) AS poll_runs
  FROM pol
  GROUP BY 1
),
top AS (
  SELECT warehouse_name, user_name AS top_poll_user_name, query_type AS top_poll_type,
         query_type || ' #' || LEFT(shape, 8) AS top_poll_shape, median_exec_ms AS top_poll_median_ms,
         cadence_s AS top_poll_every_s, runs AS top_poll_runs
  FROM pol
  QUALIFY ROW_NUMBER() OVER (PARTITION BY warehouse_name ORDER BY runs DESC, user_name, shape) = 1
),
qn AS (
  SELECT warehouse_name, COUNT(*) AS queries FROM base GROUP BY 1
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
         COALESCE(qn.queries, 0) AS queries, COALESCE(ps.poll_shapes, 0) AS poll_shapes,
         COALESCE(ps.poll_runs, 0) AS poll_runs,
         top.top_poll_user_name, top.top_poll_type, top.top_poll_shape, top.top_poll_median_ms, top.top_poll_every_s,
         top.top_poll_runs, ua.up_s AS up_s_all, COALESCE(ur.up_s, 0) AS up_s_rest,
         m.compute_credits, m.idle_credits,
         GREATEST(COALESCE(ua.up_s, 0) - COALESCE(ur.up_s, 0), 0) AS keepalive_s_raw
  FROM cfg c
  LEFT JOIN qn ON qn.warehouse_name = c.warehouse_name
  LEFT JOIN ps ON ps.warehouse_name = c.warehouse_name
  LEFT JOIN top ON top.warehouse_name = c.warehouse_name
  LEFT JOIN up_all ua ON ua.warehouse_name = c.warehouse_name
  LEFT JOIN up_rest ur ON ur.warehouse_name = c.warehouse_name
  LEFT JOIN m ON m.warehouse_name = c.warehouse_name
),
f AS (
  -- part of the idle credits, so never more than them; NULL (not $0) on a row that is NOT_ASSESSED
  SELECT r.*,
         IFF(credits_per_hour IS NULL OR cur_s IS NULL OR (compute_credits IS NOT NULL AND idle_credits IS NULL), NULL,
             IFF(poll_runs = 0, 0, LEAST(keepalive_s_raw / 3600 * credits_per_hour, GREATEST(COALESCE(idle_credits, 0), 0)))) AS keepalive_credits
  FROM r
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name, warehouse_size,
       COALESCE(warehouse_type, 'STANDARD') AS warehouse_type, credits_per_hour, auto_suspend_s, queries,
       poll_shapes, poll_runs, ROUND(100 * poll_runs / NULLIF(queries, 0), 1) AS poll_share_pct,
       ROUND(poll_runs / :period_days, 1) AS poll_runs_per_day,
       top_poll_user_name, top_poll_type, top_poll_shape, top_poll_runs, top_poll_median_ms, ROUND(top_poll_every_s, 0) AS top_poll_every_s,
       ROUND(up_s_all / 3600, 1) AS up_hours_now, ROUND(up_s_rest / 3600, 1) AS up_hours_without_polls,
       ROUND(keepalive_credits / NULLIF(credits_per_hour, 0), 1) AS keepalive_hours,
       idle_credits, keepalive_credits,
       keepalive_credits * __CREDIT_PRICE__ AS est_idle_context_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN credits_per_hour IS NULL THEN 'unknown_size'
            WHEN cur_s IS NULL THEN 'auto_suspend_off'
            WHEN compute_credits IS NOT NULL AND idle_credits IS NULL THEN 'no_query_attribution' END AS not_assessed_reason,
       CASE
         WHEN credits_per_hour IS NULL OR cur_s IS NULL OR (compute_credits IS NOT NULL AND idle_credits IS NULL) THEN 'NOT_ASSESSED'
         WHEN keepalive_credits >= :crit_credits THEN 'CRITICAL'
         WHEN keepalive_credits >= :warn_credits THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
ORDER BY keepalive_credits DESC NULLS LAST, warehouse_name
