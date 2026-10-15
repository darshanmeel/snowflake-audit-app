-- query_id: sf_task_duration_regression
-- title: Tasks that got slower
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_runs (default 5) runs: least a row needs before it can flag; :min_p50_seconds (default
--   30) p50 seconds: least a row needs before it can flag; :warn_growth_pct (default 50) growth pct: at
--   or above this the row reads WARN; :crit_growth_pct (default 100) growth pct: at or above this the
--   row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task with successful runs in the window. p50/p90 are the run times (query
--   start to completion) of SUCCEEDED runs now and in the same-length window before; p50_growth_pct is
--   the change of the median.
-- healthy: status = OK when the median run time grew less than warn_growth_pct.
-- investigate_if: WARN when p50_growth_pct >= warn_growth_pct; CRITICAL when >= crit_growth_pct. Tasks
--   whose median is under min_p50_seconds in both windows are OK (too short to matter).
-- actions: 1) compare the query profile of a recent and an older run (free); 2) check data growth in
--   the source tables and whether the task still reads only new rows (free); 3) check queuing on the
--   task warehouse, or raise its size (config / spend).
-- next: none
-- caveats: duration includes queueing on a busy warehouse. A changed task definition (see
--   last_committed_on) can explain a jump. Needs min_runs successful runs in both windows.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH __INCLUDE_sf_task_dim__,
runs AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         name AS task_name, database_name, schema_name,
         IFF(scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), 'current', 'previous') AS period,
         DATEDIFF('millisecond', query_start_time, completed_time) / 1000 AS duration_seconds,
         completed_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state = 'SUCCEEDED' AND query_start_time IS NOT NULL
),
t AS (
  SELECT task_full_name, MAX(task_name) AS task_name, MAX(database_name) AS database_name,
         MAX(schema_name) AS schema_name,
         COUNT_IF(period = 'current') AS runs,
         COUNT_IF(period = 'previous') AS prev_runs,
         MEDIAN(IFF(period = 'current', duration_seconds, NULL)) AS p50_duration_seconds,
         APPROX_PERCENTILE(IFF(period = 'current', duration_seconds, NULL), 0.9) AS p90_duration_seconds,
         MEDIAN(IFF(period = 'previous', duration_seconds, NULL)) AS prev_p50_duration_seconds,
         APPROX_PERCENTILE(IFF(period = 'previous', duration_seconds, NULL), 0.9) AS prev_p90_duration_seconds,
         SUM(IFF(period = 'current', duration_seconds, 0)) / 3600 AS run_hours,
         MAX(completed_time) AS last_run_time
  FROM runs GROUP BY 1
  HAVING COUNT_IF(period = 'current') > 0
),
scored AS (
  SELECT t.*, d.task_id, d.root_task_id, d.root_task_full_name, d.task_warehouse_name, d.last_committed_on,
         100 * (p50_duration_seconds - prev_p50_duration_seconds) / NULLIF(prev_p50_duration_seconds, 0)
           AS p50_growth_pct,
         100 * (p90_duration_seconds - prev_p90_duration_seconds) / NULLIF(prev_p90_duration_seconds, 0)
           AS p90_growth_pct
  FROM t LEFT JOIN sf_task_dim d ON d.task_full_name = t.task_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, root_task_id, root_task_full_name,
       SPLIT_PART(root_task_full_name, '.', 3) AS root_task_name,
       COALESCE(task_warehouse_name, 'SERVERLESS') AS compute,
       runs, prev_runs, p50_duration_seconds, prev_p50_duration_seconds, p50_growth_pct,
       p90_duration_seconds, prev_p90_duration_seconds, p90_growth_pct, run_hours,
       last_run_time, last_committed_on,
       last_committed_on >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AS definition_changed_recently,
       'median run ' || ROUND(prev_p50_duration_seconds) || ' s -> ' || ROUND(p50_duration_seconds) || ' s'
         AS regression_reason,
       CASE WHEN runs < :min_runs OR prev_runs < :min_runs THEN 'no_baseline' END AS not_assessed_reason,
       CASE
         WHEN runs < :min_runs OR prev_runs < :min_runs THEN 'NOT_ASSESSED'
         WHEN GREATEST(p50_duration_seconds, prev_p50_duration_seconds) < :min_p50_seconds THEN 'OK'
         WHEN p50_growth_pct >= :crit_growth_pct THEN 'CRITICAL'
         WHEN p50_growth_pct >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY p50_growth_pct DESC NULLS LAST
