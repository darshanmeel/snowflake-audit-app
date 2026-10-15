-- query_id: sf_task_start_delay
-- title: Tasks that start late, and what held them back
-- domain: jobs_pipelines   tier: standard
-- entity: tasks = task_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :late_s (default 60) seconds of delay at or above which a run counts as late; :warn_p90_s
--   (default 300) p90 delay in seconds at or above which the row reads WARN; :crit_p90_s (default 1800)
--   the same that reads CRITICAL; :min_runs (default 5) runs a task needs before it can flag
-- empty_if: no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- not_assessed_reasons: too_few_runs: the task ran fewer than min_runs times in the window, too few to
--   judge
-- read_this: one row = one standalone or root task that ran on its schedule (or its stream trigger) in
--   the window. A run's delay is the time from its scheduled time until its statement runs, in three
--   parts: scheduler_wait (scheduled time to the statement's start: the scheduler or serverless compute
--   was late), resume_wait (QUEUED_PROVISIONING_TIME: the warehouse was resuming or resizing) and
--   queue_wait (QUEUED_OVERLOAD_TIME: the warehouse was busy with other work). p50/p90_delay_s are per
--   run; *_share_pct split the summed delay between the three parts and main_cause names the largest
--   (empty when no run was late).
--   late_pct is the share of runs late by late_s or more; delay_to_interval_pct compares the p90 delay
--   to the typical gap between runs.
-- healthy: status = OK when the p90 delay stays under warn_p90_s.
-- investigate_if: WARN when p90_delay_s >= warn_p90_s; CRITICAL when p90_delay_s >= crit_p90_s.
-- actions: 1) queue_wait: move the task off the busy hour or to its own warehouse, or let it run
--   serverless (config); 2) resume_wait: start the warehouse a little earlier or keep it up through the
--   batch window (config); 3) scheduler_wait: spread schedules away from the top of the hour, or use
--   TARGET_COMPLETION_INTERVAL on serverless tasks (free)
-- next: sf_task_skipped_overlaps, sf_task_warehouse_vs_serverless
-- caveats: heavy: reads QUERY_HISTORY for the window (period_days only), only the task statements and
--   only their three timing columns. Child tasks in a graph are left out: when they start depends on
--   their parents, so their delay is not the scheduler's. Runs that were skipped, retried or started by
--   hand (EXECUTE TASK) are left out. TASK_HISTORY lags up to 45 minutes.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH -- Latest known definition of every task, keyed by full name (database.schema.task), because
-- TASK_HISTORY carries names while SERVERLESS_TASK_HISTORY and SHOW TASKS carry the id.
-- warehouse_name is NULL for a serverless task. Dropped tasks stay, so history still resolves.
sf_task_dim AS (
  SELECT x.*, r.root_name AS root_task_full_name
  FROM (
    SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
           MAX_BY(TO_VARCHAR(id), last_committed_on) AS task_id,
           MAX_BY(TO_VARCHAR(root_task_id), last_committed_on) AS root_task_id,
           MAX_BY(warehouse_name, last_committed_on) AS task_warehouse_name,
           MAX_BY(schedule, last_committed_on) AS task_schedule,
           MAX(last_committed_on) AS last_committed_on
    FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
    GROUP BY 1
  ) x
  -- the root task's own full name, so a graph reads as name (id), never a bare id
  LEFT JOIN (
    SELECT TO_VARCHAR(id) AS task_id,
           MAX_BY(database_name || '.' || schema_name || '.' || name, last_committed_on) AS root_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
    GROUP BY 1
  ) r ON r.task_id = x.root_task_id
),
runs AS (
  SELECT th.database_name || '.' || th.schema_name || '.' || th.name AS task_full_name, th.name AS task_name,
         th.database_name, th.schema_name, th.query_id, th.scheduled_time, th.root_task_id,
         GREATEST(DATEDIFF(millisecond, th.scheduled_time, th.query_start_time), 0) / 1000 AS scheduler_wait_s
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY th
  WHERE th.scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND th.scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(th.database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND th.state IN ('SUCCEEDED', 'FAILED', 'CANCELLED') AND th.query_start_time IS NOT NULL
    AND th.scheduled_from IN ('SCHEDULE', 'TRIGGER') AND COALESCE(th.attempt_number, 1) = 1
),
own AS (
  -- a standalone or root task is its own root; children are left out
  SELECT r.*, d.task_id, d.task_warehouse_name, d.task_schedule
  FROM runs r
  JOIN sf_task_dim d ON d.task_full_name = r.task_full_name
  WHERE d.task_id = r.root_task_id
),
qh AS (
  SELECT query_id, queued_provisioning_time, queued_overload_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__)
    AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
    AND query_id IN (SELECT query_id FROM own WHERE query_id IS NOT NULL)
),
d AS (
  SELECT o.*, COALESCE(q.queued_provisioning_time, 0) / 1000 AS resume_wait_s,
         COALESCE(q.queued_overload_time, 0) / 1000 AS queue_wait_s,
         o.scheduler_wait_s + COALESCE(q.queued_provisioning_time, 0) / 1000 + COALESCE(q.queued_overload_time, 0) / 1000 AS delay_s
  FROM own o
  LEFT JOIN qh q ON q.query_id = o.query_id
),
gaps AS (
  SELECT task_full_name,
         DATEDIFF(second, LAG(scheduled_time) OVER (PARTITION BY task_full_name ORDER BY scheduled_time), scheduled_time) AS gap_s
  FROM d
),
g AS (
  SELECT task_full_name, MEDIAN(gap_s) AS median_interval_s FROM gaps WHERE gap_s > 0 GROUP BY 1
),
t AS (
  SELECT task_full_name, MAX(task_name) AS task_name, MAX(task_id) AS task_id, MAX(database_name) AS database_name,
         MAX(schema_name) AS schema_name, MAX(task_warehouse_name) AS warehouse_name, MAX(task_schedule) AS task_schedule,
         COUNT(*) AS runs, COUNT_IF(delay_s >= :late_s) AS late_runs,
         MEDIAN(delay_s) AS p50_delay_s, APPROX_PERCENTILE(delay_s, 0.9) AS p90_delay_s, MAX(delay_s) AS max_delay_s,
         SUM(scheduler_wait_s) AS scheduler_wait_s, SUM(resume_wait_s) AS resume_wait_s, SUM(queue_wait_s) AS queue_wait_s,
         SUM(delay_s) AS delay_total_s
  FROM d
  GROUP BY 1
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, t.task_full_name, t.task_name, t.task_id,
       t.database_name, t.schema_name, t.warehouse_name, t.task_schedule, t.runs, t.late_runs,
       ROUND(100 * t.late_runs / NULLIF(t.runs, 0), 1) AS late_pct,
       ROUND(t.p50_delay_s, 1) AS p50_delay_s, ROUND(t.p90_delay_s, 1) AS p90_delay_s, ROUND(t.max_delay_s, 1) AS max_delay_s,
       ROUND(100 * t.scheduler_wait_s / NULLIF(t.delay_total_s, 0), 1) AS scheduler_share_pct,
       ROUND(100 * t.resume_wait_s / NULLIF(t.delay_total_s, 0), 1) AS resume_share_pct,
       ROUND(100 * t.queue_wait_s / NULLIF(t.delay_total_s, 0), 1) AS queue_share_pct,
       CASE WHEN t.late_runs = 0 OR t.delay_total_s <= 0 THEN NULL
            WHEN t.queue_wait_s >= t.resume_wait_s AND t.queue_wait_s >= t.scheduler_wait_s THEN 'warehouse_busy'
            WHEN t.resume_wait_s >= t.scheduler_wait_s THEN 'warehouse_resume'
            ELSE 'scheduler' END AS main_cause,
       g.median_interval_s, ROUND(100 * t.p90_delay_s / NULLIF(g.median_interval_s, 0), 1) AS delay_to_interval_pct,
       CASE WHEN t.runs < :min_runs THEN 'too_few_runs' END AS not_assessed_reason,
       CASE
         WHEN t.runs < :min_runs THEN 'NOT_ASSESSED'
         WHEN t.p90_delay_s >= :crit_p90_s THEN 'CRITICAL'
         WHEN t.p90_delay_s >= :warn_p90_s THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM t
LEFT JOIN g ON g.task_full_name = t.task_full_name
ORDER BY t.p90_delay_s DESC NULLS LAST, t.task_full_name
