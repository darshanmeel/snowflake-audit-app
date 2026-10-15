-- query_id: sf_task_runs_daily
-- title: Task runs per day, by state
-- domain: jobs_pipelines   tier: standard
-- entity: tasks = task_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- empty_if: role_cannot_see, no_activity
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :slow_factor (default 2) a run that took more than this many times the task's median run in
--   the window counts as slow
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one task (database.schema.task) on one UTC day it had a completed run, by
--   scheduled time. succeeded_runs, failed_runs, cancelled_runs and skipped_runs count that day's runs
--   by state; slow_runs counts the succeeded or failed runs that took more than :slow_factor times the
--   task's median succeeded run in the window. A day with no row had no completed run. last_error_code
--   is the day's latest failure's code (the message is never read). Read it as a grid: rows are tasks,
--   columns are days.
-- healthy: n/a - inventory (the per-task verdict is sf_task_failures)
-- investigate_if: n/a - inventory; a row of failed days in a row is a task failing now
-- actions: n/a - inventory, nothing to act on; see sf_task_failures
-- next: sf_task_failures
-- caveats: TASK_HISTORY lags up to 45 minutes and lists completed runs only (a run still executing is not
--   here). A retry is its own run. The task id comes from TASK_VERSIONS by full name, so a dropped and
--   recreated task shows its newest id. Run time is query start to completion; a skipped run has none.
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
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         DATE(scheduled_time) AS run_date, scheduled_time, state, error_code,
         DATEDIFF(millisecond, query_start_time, completed_time) / 1000 AS run_s
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state IN ('SUCCEEDED', 'FAILED', 'CANCELLED', 'SKIPPED')
),
med AS (
  SELECT task_full_name, MEDIAN(run_s) AS median_run_s
  FROM runs WHERE state = 'SUCCEEDED' AND run_s IS NOT NULL
  GROUP BY 1
),
d AS (
  SELECT r.task_full_name, r.run_date,
         COUNT_IF(r.state = 'SUCCEEDED') AS succeeded_runs,
         COUNT_IF(r.state = 'FAILED') AS failed_runs,
         COUNT_IF(r.state = 'CANCELLED') AS cancelled_runs,
         COUNT_IF(r.state = 'SKIPPED') AS skipped_runs,
         -- A median under 1 s is too short to call a run slow against.
         COUNT_IF(r.state IN ('SUCCEEDED', 'FAILED') AND m.median_run_s >= 1
                  AND r.run_s > :slow_factor * m.median_run_s) AS slow_runs,
         MAX(m.median_run_s) AS median_run_s,
         MAX(r.run_s) AS longest_run_s,
         MAX_BY(r.error_code, IFF(r.state = 'FAILED', r.scheduled_time, NULL)) AS last_error_code
  FROM runs r LEFT JOIN med m ON m.task_full_name = r.task_full_name
  GROUP BY r.task_full_name, r.run_date
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, d.run_date,
       d.task_full_name, SPLIT_PART(d.task_full_name, '.', 3) AS task_name, t.task_id,
       t.root_task_id, t.root_task_full_name,
       COALESCE(t.task_warehouse_name, IFF(t.task_id IS NULL, NULL, 'SERVERLESS')) AS compute,
       d.succeeded_runs + d.failed_runs + d.cancelled_runs AS runs,
       d.succeeded_runs, d.failed_runs, d.cancelled_runs, d.skipped_runs, d.slow_runs,
       d.median_run_s, d.longest_run_s, d.last_error_code,
       CASE WHEN d.failed_runs > 0 THEN 'failed'
            WHEN d.slow_runs > 0 THEN 'slow'
            WHEN d.succeeded_runs > 0 THEN 'ok'
            WHEN d.cancelled_runs > 0 THEN 'cancelled'
            ELSE 'skipped' END AS day_state
FROM d
LEFT JOIN sf_task_dim t ON t.task_full_name = d.task_full_name
ORDER BY d.task_full_name, d.run_date
