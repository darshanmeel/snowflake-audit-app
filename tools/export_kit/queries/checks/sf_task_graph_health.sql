-- query_id: sf_task_graph_health
-- title: Task graph runs that fail or slow down
-- domain: jobs_pipelines   tier: standard
-- entity: task graphs = root_task_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COMPLETE_TASK_GRAPHS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failure_pct (default 5) failure pct: at or above this the row reads WARN;
--   :crit_failure_pct (default 25) failure pct: at or above this the row reads CRITICAL;
--   :crit_consecutive_failures (default 3) consecutive failures: at or above this the row reads
--   CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this the row reads WARN; :min_runs
--   (default 5) runs: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task graph (DAG), named by its root task. A graph run fails when any task in
--   it fails; first_error_* names the task that broke it. Duration is scheduled time to completion of
--   the whole graph, so it includes waiting and every child task.
-- healthy: status = OK when no graph run failed and the median duration did not grow.
-- investigate_if: WARN when failure_pct >= warn_failure_pct, the latest run failed, or the median
--   duration grew >= warn_growth_pct; CRITICAL when failure_pct >= crit_failure_pct or
--   consecutive_failures >= crit_consecutive_failures.
-- actions: 1) fix the task named in last_first_error_task_name (free); 2) set a FINALIZE task or
--   ERROR_INTEGRATION on the root so failures notify and clean up (config); 3) use
--   TASK_AUTO_RETRY_ATTEMPTS for transient errors (config).
-- next: none
-- caveats: COMPLETE_TASK_GRAPHS lags up to 45 minutes and lists only finished runs. Retried runs count
--   once per attempt (see retried_runs). The same root name in a recreated graph shares a row only when
--   root_task_id is unchanged.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH g AS (
  SELECT TO_VARCHAR(root_task_id) AS root_task_id,
         database_name || '.' || schema_name || '.' || root_task_name AS root_task_full_name,
         root_task_name, database_name, schema_name, state, scheduled_time, completed_time,
         first_error_task_name, first_error_code, first_error_message, attempt_number,
         IFF(scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), 'current', 'previous') AS period,
         DATEDIFF('millisecond', scheduled_time, completed_time) / 60000 AS duration_minutes,
         state IN ('FAILED', 'CANCELLED') AS is_bad
  FROM SNOWFLAKE.ACCOUNT_USAGE.COMPLETE_TASK_GRAPHS
  WHERE scheduled_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
),
cur AS (
  SELECT root_task_id, MAX(IFF(state = 'SUCCEEDED', scheduled_time, NULL)) AS last_success_time
  FROM g WHERE period = 'current' GROUP BY 1
),
t AS (
  SELECT g.root_task_id, MAX_BY(g.root_task_full_name, g.scheduled_time) AS root_task_full_name,
         MAX_BY(g.root_task_name, g.scheduled_time) AS root_task_name,
         MAX_BY(g.database_name, g.scheduled_time) AS database_name,
         MAX_BY(g.schema_name, g.scheduled_time) AS schema_name,
         COUNT_IF(g.period = 'current') AS runs,
         COUNT_IF(g.period = 'current' AND g.state = 'SUCCEEDED') AS succeeded_runs,
         COUNT_IF(g.period = 'current' AND g.state = 'FAILED') AS failed_runs,
         COUNT_IF(g.period = 'current' AND g.state = 'CANCELLED') AS cancelled_runs,
         COUNT_IF(g.period = 'current' AND g.attempt_number > 1) AS retried_runs,
         COUNT_IF(g.period = 'current' AND g.is_bad
                  AND g.scheduled_time > COALESCE(c.last_success_time, '1970-01-01'::TIMESTAMP_LTZ))
           AS consecutive_failures,
         MAX_BY(g.state, IFF(g.period = 'current', g.scheduled_time, NULL)) AS last_state,
         MAX(IFF(g.period = 'current', g.completed_time, NULL)) AS last_run_time,
         MAX(IFF(g.period = 'current' AND g.is_bad, g.scheduled_time, NULL)) AS last_failure_time,
         MAX_BY(g.first_error_task_name, IFF(g.period = 'current' AND g.is_bad, g.scheduled_time, NULL))
           AS last_first_error_task_name,
         MAX_BY(g.first_error_code, IFF(g.period = 'current' AND g.is_bad, g.scheduled_time, NULL))
           AS last_first_error_code,
         MAX_BY(g.first_error_message, IFF(g.period = 'current' AND g.is_bad, g.scheduled_time, NULL))
           AS last_first_error_message,
         MEDIAN(IFF(g.period = 'current' AND g.state = 'SUCCEEDED', g.duration_minutes, NULL)) AS p50_duration_minutes,
         APPROX_PERCENTILE(IFF(g.period = 'current' AND g.state = 'SUCCEEDED', g.duration_minutes, NULL), 0.9)
           AS p90_duration_minutes,
         MAX(IFF(g.period = 'current', g.duration_minutes, NULL)) AS max_duration_minutes,
         COUNT_IF(g.period = 'previous' AND g.state = 'SUCCEEDED') AS prev_succeeded_runs,
         MEDIAN(IFF(g.period = 'previous' AND g.state = 'SUCCEEDED', g.duration_minutes, NULL))
           AS prev_p50_duration_minutes
  FROM g LEFT JOIN cur c ON c.root_task_id = g.root_task_id
  GROUP BY g.root_task_id
  HAVING COUNT_IF(g.period = 'current') > 0
),
scored AS (
  SELECT t.*,
         100 * (failed_runs + cancelled_runs) / NULLIF(runs, 0) AS failure_pct,
         IFF(prev_succeeded_runs >= :min_runs AND succeeded_runs >= :min_runs,
             100 * (p50_duration_minutes - prev_p50_duration_minutes) / NULLIF(prev_p50_duration_minutes, 0),
             NULL) AS p50_growth_pct
  FROM t
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       root_task_full_name, root_task_name, root_task_id, database_name, schema_name,
       runs, succeeded_runs, failed_runs, cancelled_runs, retried_runs, failure_pct,
       consecutive_failures, last_state, last_run_time, last_failure_time,
       last_first_error_task_name, last_first_error_code,
       LEFT(REGEXP_REPLACE(REGEXP_REPLACE(last_first_error_message, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'), '''[^'']*''', '?'), 500) AS last_first_error_message,
       p50_duration_minutes, p90_duration_minutes, max_duration_minutes, prev_p50_duration_minutes,
       p50_growth_pct,
       (failed_runs + cancelled_runs) || ' of ' || runs || ' graph runs failed or were cancelled; median '
         || ROUND(p50_duration_minutes, 1) || ' min' AS graph_reason,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN failure_pct >= :crit_failure_pct OR consecutive_failures >= :crit_consecutive_failures THEN 'CRITICAL'
         WHEN (failed_runs + cancelled_runs > 0 AND failure_pct >= :warn_failure_pct)
           OR last_state IN ('FAILED', 'CANCELLED')
           OR p50_growth_pct >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, failed_runs + cancelled_runs DESC
