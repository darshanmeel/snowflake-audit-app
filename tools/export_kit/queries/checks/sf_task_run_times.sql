-- query_id: sf_task_run_times
-- title: How long each task runs, and what its failed runs cost
-- domain: jobs_pipelines   tier: standard
-- money: est_failed_usd_list
-- entity: tasks = task_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- empty_if: role_cannot_see, no_activity
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task (database.schema.task) that ran in the window. runs counts completed
--   runs (skipped runs are in skipped_runs); avg/p95/max/total_run_s are query start to completion;
--   runs_with_retry counts runs with ATTEMPT_NUMBER > 1. failed_run_credits_lower_bound is for
--   serverless tasks only: the credits of the SERVERLESS_TASK_HISTORY rows that overlap a failed run,
--   split by failed run seconds against all run seconds in those rows. It is a lower bound, not the
--   cost of failure; warehouse tasks read NULL (their warehouse cost cannot be split per run), and so do
--   serverless tasks with no billing row in the window. failed_cost_note says which.
-- healthy: status = OK when no run failed and no run needed a retry.
-- investigate_if: WARN when failed_runs > 0 or runs_with_retry > 0.
-- actions: 1) fix the cause of the failed runs (error code in sf_task_failures) so retries stop (free);
--   2) set a USER_TASK_TIMEOUT_MS that fits p95_run_s so a hung run fails fast (config); 3) review
--   TASK_AUTO_RETRY_ATTEMPTS: each retry pays for the run again (config).
-- next: sf_task_failures
-- caveats: TASK_HISTORY lags up to 45 minutes and lists completed runs only; SERVERLESS_TASK_HISTORY
--   lags up to 3 hours. A run that failed before its query started has no run time. Only billing rows
--   wholly inside the window are split. compute is blank when the role cannot see the task in
--   TASK_VERSIONS. The failed-run
--   credits are a lower bound: credits in rows with no failed run are left out, a row shared with
--   successful runs is split by run seconds, and failed retries before the last attempt still count
--   only by their own seconds. The task id comes from TASK_VERSIONS by full name, so a dropped and
--   recreated task shows its newest id.
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
         name AS task_name, database_name, schema_name, state, scheduled_time, query_start_time,
         completed_time, attempt_number,
         DATEDIFF('millisecond', query_start_time, completed_time) / 1000.0 AS run_s
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
),
t AS (
  SELECT task_full_name, MAX(task_name) AS task_name, MAX(database_name) AS database_name,
         MAX(schema_name) AS schema_name,
         COUNT_IF(state <> 'SKIPPED') AS runs,
         COUNT_IF(state = 'SUCCEEDED') AS succeeded_runs,
         COUNT_IF(state = 'FAILED') AS failed_runs,
         COUNT_IF(state = 'CANCELLED') AS cancelled_runs,
         COUNT_IF(state = 'SKIPPED') AS skipped_runs,
         COUNT_IF(state <> 'SKIPPED' AND attempt_number > 1) AS runs_with_retry,
         AVG(IFF(state <> 'SKIPPED', run_s, NULL)) AS avg_run_s,
         PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY IFF(state <> 'SKIPPED', run_s, NULL)) AS p95_run_s,
         MAX(IFF(state <> 'SKIPPED', run_s, NULL)) AS max_run_s,
         SUM(IFF(state <> 'SKIPPED', run_s, NULL)) AS total_run_s,
         SUM(IFF(state = 'FAILED', run_s, NULL)) AS failed_run_s,
         MAX(IFF(state <> 'SKIPPED', completed_time, NULL)) AS last_run_time,
         MAX_BY(state, IFF(state <> 'SKIPPED', scheduled_time, NULL)) AS last_state
  FROM runs
  GROUP BY 1
),
sl AS (
  SELECT database_name || '.' || schema_name || '.' || task_name AS task_full_name,
         TO_VARCHAR(task_id) AS task_id, start_time, end_time,
         TRY_TO_DOUBLE(TO_VARCHAR(credits_used)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
  -- only rows wholly inside the window, so runs outside it never shrink a row's split
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND end_time <= __AS_OF_DATE__
),
-- Run seconds clipped to each billing row, so a row shared by several runs is split by their time.
sl_split AS (
  SELECT s.task_full_name, s.start_time, s.credits,
         SUM(GREATEST(0, DATEDIFF('millisecond', GREATEST(r.query_start_time, s.start_time),
                                  LEAST(r.completed_time, s.end_time)) / 1000.0)) AS row_run_s,
         SUM(IFF(r.state = 'FAILED',
                 GREATEST(0, DATEDIFF('millisecond', GREATEST(r.query_start_time, s.start_time),
                                      LEAST(r.completed_time, s.end_time)) / 1000.0), 0)) AS row_failed_s
  FROM sl s
  JOIN runs r ON r.task_full_name = s.task_full_name AND r.state <> 'SKIPPED'
             AND r.query_start_time < s.end_time AND r.completed_time > s.start_time
  GROUP BY s.task_full_name, s.start_time, s.credits
),
fc AS (
  SELECT task_full_name, SUM(credits * row_failed_s / NULLIF(row_run_s, 0)) AS failed_credits
  FROM sl_split
  WHERE row_failed_s > 0
  GROUP BY 1
),
sl_id AS (
  SELECT task_full_name, MAX(task_id) AS task_id FROM sl GROUP BY 1
),
j AS (
  SELECT t.*, COALESCE(i.task_id, d.task_id) AS task_id, d.root_task_id, d.root_task_full_name,
         d.task_warehouse_name,
         -- a task missing from TASK_VERSIONS (role can't see it) is not assumed serverless
         i.task_full_name IS NOT NULL OR (d.task_full_name IS NOT NULL AND d.task_warehouse_name IS NULL)
           AS is_serverless,
         i.task_full_name IS NOT NULL AS has_billing_rows,
         -- no billing row for the task in the window leaves nothing to bound with: NULL, never 0
         IFF(i.task_full_name IS NOT NULL, COALESCE(fc.failed_credits, 0), NULL)
           AS failed_run_credits_lower_bound
  FROM t
  LEFT JOIN sf_task_dim d ON d.task_full_name = t.task_full_name
  LEFT JOIN sl_id i ON i.task_full_name = t.task_full_name
  LEFT JOIN fc ON fc.task_full_name = t.task_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, root_task_id, root_task_full_name,
       SPLIT_PART(root_task_full_name, '.', 3) AS root_task_name,
       CASE WHEN is_serverless THEN 'SERVERLESS' ELSE task_warehouse_name END AS compute,
       runs, succeeded_runs, failed_runs, cancelled_runs, skipped_runs, runs_with_retry,
       ROUND(avg_run_s, 1) AS avg_run_s, ROUND(p95_run_s, 1) AS p95_run_s, ROUND(max_run_s, 1) AS max_run_s,
       ROUND(total_run_s, 1) AS total_run_s, ROUND(COALESCE(failed_run_s, 0), 1) AS failed_run_s,
       last_run_time, last_state,
       failed_run_credits_lower_bound,
       failed_run_credits_lower_bound * __CREDIT_PRICE__ AS est_failed_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CASE WHEN NOT is_serverless AND task_warehouse_name IS NULL
              THEN 'compute unknown: the task is not in TASK_VERSIONS for this role'
            WHEN NOT is_serverless THEN 'warehouse task: its warehouse cost cannot be split per run'
            WHEN NOT has_billing_rows THEN 'serverless: no SERVERLESS_TASK_HISTORY rows for this task in the window'
            WHEN failed_runs = 0 THEN 'serverless: no failed runs'
            ELSE 'serverless: lower bound from billing rows that overlap failed runs' END AS failed_cost_note,
       CASE WHEN failed_runs = 0 AND runs_with_retry = 0 THEN 'no failed or retried runs'
            ELSE failed_runs || ' of ' || runs || ' runs failed; ' || runs_with_retry
                 || ' runs were retries' END AS run_reason,
       CASE WHEN runs = 0 THEN 'only_skipped_runs' END AS not_assessed_reason,
       CASE
         WHEN runs = 0 THEN 'NOT_ASSESSED'
         WHEN failed_runs > 0 OR runs_with_retry > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM j
ORDER BY CASE status WHEN 'WARN' THEN 0 WHEN 'OK' THEN 1 ELSE 2 END, failed_run_s DESC, total_run_s DESC NULLS LAST
