-- query_id: sf_task_warehouse_vs_serverless
-- title: Short warehouse tasks that keep a warehouse awake
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- pre: SHOW WAREHOUSES
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY, SHOW WAREHOUSES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database; MONITOR on the warehouses (SHOW WAREHOUSES
--   lists only warehouses the role can see)
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :short_seconds (default 60) short seconds: value this check uses; :min_runs_per_day (default
--   4) runs per day: least a row needs before it can flag; :min_task_query_share_pct (default 50) task
--   query share pct: least a row needs before it can flag; :warn_idle_pct (default 40) idle pct: at or
--   above this the row reads WARN; :warn_usd (default 20) usd: at or above this the row reads WARN;
--   :crit_usd (default 200) usd: at or above this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task that runs on a user warehouse. task_query_share_pct is the task's share
--   of all queries on that warehouse; when tasks are most of what a warehouse does, its idle time
--   (billed with no query running: the 60 s minimum and the auto-suspend tail) is mostly caused by
--   them. est_idle_context_usd_list charges the warehouse's idle credits to the task by that share.
--   est_idle_context_usd_list is context, not waste: the warehouse's idle is counted once, as possible
--   waste, in sf_wh_idle_minutes; this row only shows how much of it these tasks account for.
-- healthy: status = OK when the task is long enough, rare, or shares a busy warehouse.
-- investigate_if: WARN when the median run is under short_seconds, it runs at least min_runs_per_day,
--   is >= min_task_query_share_pct of the warehouse's queries and the warehouse is >= warn_idle_pct
--   idle, with est_idle_context_usd_list >= warn_usd; CRITICAL when that is >= crit_usd.
-- actions: 1) drop the WAREHOUSE parameter to make it a serverless task, billed per second of use with
--   no idle tail (config); 2) or lower AUTO_SUSPEND on a warehouse used only by tasks (config); 3)
--   group several small tasks into one graph on one schedule so they share one wake-up (free).
-- next: none
-- caveats: an estimate: idle is split by query count, not by who woke the warehouse. Serverless tasks
--   bill compute at their own multiplier, so the saving is below est_idle_context_usd_list; check it with
--   sf_task_cost after a switch. Task statements that run a procedure count as one query.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH __INCLUDE_sf_task_dim__,
__INCLUDE_warehouse_config__,
runs AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         name AS task_name, database_name, schema_name, query_id,
         DATEDIFF('millisecond', query_start_time, completed_time) / 1000 AS duration_seconds
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state IN ('SUCCEEDED', 'FAILED') AND query_id IS NOT NULL
),
qh AS (
  SELECT query_id, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
    AND warehouse_id IS NOT NULL
),
wh_queries AS (
  SELECT warehouse_id, COUNT(*) AS warehouse_queries
  FROM qh GROUP BY 1
),
attr AS (
  SELECT COALESCE(root_query_id, query_id) AS task_query_id,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY 1
),
wm AS (
  SELECT TO_VARCHAR(warehouse_id) AS warehouse_id,
         SUM(credits_used_compute) AS warehouse_credits,
         -- Idle uses only hours older than the 8 h lag with a split; a warehouse with none (adaptive) is left NULL.
         IFF(COUNT_IF(credits_used_compute > 0 AND start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL) > 0,
             GREATEST(SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()) AND credits_attributed_compute_queries IS NOT NULL, credits_used_compute, 0))
                      - SUM(IFF(start_time < DATEADD(hour, -8, CURRENT_TIMESTAMP()), credits_attributed_compute_queries, 0)), 0), NULL)
           AS warehouse_idle_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
t AS (
  SELECT r.task_full_name, MAX(r.task_name) AS task_name, MAX(r.database_name) AS database_name,
         MAX(r.schema_name) AS schema_name, q.warehouse_id, MAX(q.warehouse_name) AS warehouse_name,
         COUNT(*) AS runs,
         MEDIAN(r.duration_seconds) AS p50_duration_seconds,
         SUM(COALESCE(a.credits, 0)) AS task_credits
  FROM runs r
  JOIN qh q ON q.query_id = r.query_id
  LEFT JOIN attr a ON a.task_query_id = r.query_id
  GROUP BY r.task_full_name, q.warehouse_id
),
scored AS (
  SELECT t.*, d.task_id, d.root_task_id, d.root_task_full_name, d.task_warehouse_name,
         w.warehouse_credits, w.warehouse_idle_credits, c.auto_stop_minutes,
         t.runs / :period_days AS runs_per_day,
         100 * t.runs / NULLIF(wq.warehouse_queries, 0) AS task_query_share_pct,
         100 * w.warehouse_idle_credits / NULLIF(w.warehouse_credits, 0) AS warehouse_idle_pct,
         w.warehouse_idle_credits * t.runs / NULLIF(wq.warehouse_queries, 0) AS idle_credits_share
  FROM t
  LEFT JOIN sf_task_dim d ON d.task_full_name = t.task_full_name
  LEFT JOIN wh_queries wq ON wq.warehouse_id = t.warehouse_id
  LEFT JOIN wm w ON w.warehouse_id = t.warehouse_id
  LEFT JOIN warehouse_config c ON c.warehouse_id = t.warehouse_id
),
flagged AS (
  SELECT scored.*,
         idle_credits_share * __CREDIT_PRICE__ AS idle_usd,
         p50_duration_seconds < :short_seconds AND runs_per_day >= :min_runs_per_day
           AND task_query_share_pct >= :min_task_query_share_pct
           AND warehouse_idle_pct >= :warn_idle_pct AS is_candidate
  FROM scored
  -- Serverless tasks also show a system warehouse in QUERY_HISTORY; keep user warehouses only.
  WHERE warehouse_credits IS NOT NULL
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, root_task_id, root_task_full_name,
       SPLIT_PART(root_task_full_name, '.', 3) AS root_task_name,
       warehouse_name, warehouse_id, CAST(auto_stop_minutes AS INTEGER) AS auto_stop_minutes,
       runs, runs_per_day, p50_duration_seconds, task_credits, task_query_share_pct,
       warehouse_credits, warehouse_idle_credits, warehouse_idle_pct, idle_credits_share,
       task_credits * __CREDIT_PRICE__ AS est_task_usd_list,
       idle_usd AS est_idle_context_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       is_candidate AS serverless_candidate,
       ROUND(runs_per_day, 1) || ' runs/day of ~' || ROUND(p50_duration_seconds) || ' s; '
         || ROUND(task_query_share_pct) || '% of the warehouse''s queries; warehouse '
         || ROUND(warehouse_idle_pct) || '% idle' AS candidate_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN warehouse_credits = 0 THEN 'no_warehouse_credits'
            WHEN warehouse_idle_credits IS NULL THEN 'no_query_attribution' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR warehouse_credits = 0 OR warehouse_idle_credits IS NULL THEN 'NOT_ASSESSED'
         WHEN is_candidate AND idle_usd >= :crit_usd THEN 'CRITICAL'
         WHEN is_candidate AND idle_usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM flagged
ORDER BY est_idle_context_usd_list DESC NULLS LAST
