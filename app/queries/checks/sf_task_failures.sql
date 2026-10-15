-- query_id: sf_task_failures
-- title: Tasks that fail
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failure_pct (default 5) failure pct: at or above this the row reads WARN;
--   :crit_failure_pct (default 25) failure pct: at or above this the row reads CRITICAL;
--   :crit_consecutive_failures (default 3) consecutive failures: at or above this the row reads
--   CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task (database.schema.task) that ran in the window. failed_runs counts
--   FAILED runs; consecutive_failures counts the failed runs since the
--   last success (a task that is failing right now); last_error_code is the latest failure's error code (the message is never read).
-- healthy: status = OK when the task did not fail in the window.
-- investigate_if: WARN when any run failed and failure_rate_pct >= warn_failure_pct, or the latest run
--   failed; CRITICAL when failure_rate_pct >= crit_failure_pct, consecutive_failures >=
--   crit_consecutive_failures. Tasks Snowflake auto-suspended after failures are in
--   sf_task_suspended_or_stale.
-- actions: 1) open the failed run in Snowsight, look up its error code and fix the SQL, grants or upstream data (free); 2) set
--   ERROR_INTEGRATION on the root task so failures notify someone (config); 3) review
--   SUSPEND_TASK_AFTER_NUM_FAILURES and TASK_AUTO_RETRY_ATTEMPTS (config).
-- next: none
-- caveats: ACCOUNT_USAGE.TASK_HISTORY lags up to 45 minutes and omits runs still executing. The task id
--   comes from TASK_VERSIONS by full name, so a dropped and recreated task shows its newest id. A
--   failure in a stored procedure the task calls is the task's failure. The error message is not exported,
--   only the code.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH __INCLUDE_sf_task_dim__,
runs AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         name AS task_name, database_name, schema_name, state, error_code,
         scheduled_time, completed_time,
         state = 'FAILED' AS is_failed
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
),
last_ok AS (
  SELECT task_full_name, MAX(IFF(state = 'SUCCEEDED', scheduled_time, NULL)) AS last_success_time
  FROM runs GROUP BY 1
),
t AS (
  SELECT r.task_full_name, MAX(r.task_name) AS task_name, MAX(r.database_name) AS database_name,
         MAX(r.schema_name) AS schema_name,
         COUNT_IF(r.state <> 'SKIPPED') AS runs,
         COUNT_IF(r.state = 'SUCCEEDED') AS succeeded_runs,
         COUNT_IF(r.is_failed) AS failed_runs,
         COUNT_IF(r.state = 'CANCELLED') AS cancelled_runs,
         COUNT_IF(r.state = 'SKIPPED') AS skipped_runs,
         COUNT_IF(r.is_failed AND r.scheduled_time > COALESCE(l.last_success_time, '1970-01-01'::TIMESTAMP_LTZ))
           AS consecutive_failures,
         MAX(l.last_success_time) AS last_success_time,
         MAX_BY(r.state, IFF(r.state <> 'SKIPPED', r.scheduled_time, NULL)) AS last_state,
         MAX(IFF(r.state <> 'SKIPPED', r.completed_time, NULL)) AS last_run_time,
         MAX(IFF(r.is_failed, r.scheduled_time, NULL)) AS last_failure_time,
         MAX_BY(r.error_code, IFF(r.is_failed, r.scheduled_time, NULL)) AS last_error_code
  FROM runs r JOIN last_ok l ON l.task_full_name = r.task_full_name
  GROUP BY r.task_full_name
),
scored AS (
  SELECT t.*, d.task_id, d.root_task_id, d.root_task_full_name, d.task_warehouse_name,
         100 * failed_runs / NULLIF(runs, 0) AS failure_rate_pct
  FROM t LEFT JOIN sf_task_dim d ON d.task_full_name = t.task_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, root_task_id, root_task_full_name,
       SPLIT_PART(root_task_full_name, '.', 3) AS root_task_name,
       COALESCE(task_warehouse_name, 'SERVERLESS') AS compute,
       runs, succeeded_runs, failed_runs, cancelled_runs, skipped_runs,
       failure_rate_pct, consecutive_failures, last_state, last_run_time, last_success_time,
       last_failure_time, last_error_code,
       CASE WHEN failed_runs = 0 THEN 'no failures'
            ELSE failed_runs || ' of ' || runs || ' runs failed; ' || consecutive_failures
                 || ' in a row since the last success' END AS failure_reason,
       CASE WHEN runs = 0 THEN 'only_skipped_runs' END AS not_assessed_reason,
       CASE
         WHEN runs = 0 THEN 'NOT_ASSESSED'
         WHEN failed_runs = 0 THEN 'OK'
         WHEN failure_rate_pct >= :crit_failure_pct OR consecutive_failures >= :crit_consecutive_failures THEN 'CRITICAL'
         WHEN failure_rate_pct >= :warn_failure_pct OR last_state = 'FAILED' THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failed_runs DESC
