-- query_id: sf_task_suspended_or_stale
-- shims: TASK_HISTORY
-- reads: INFORMATION_SCHEMA table functions TASK_HISTORY
-- fallback_note: task runs for the last 7 days at most, up to 10,000 a day, only tasks this role owns or can monitor (MONITOR EXECUTION shows all)
-- pre: SHOW TASKS IN ACCOUNT
WITH shown AS (
  SELECT s."database_name" || '.' || s."schema_name" || '.' || s."name" AS task_full_name,
         s."name" AS task_name, TO_VARCHAR(s."id") AS task_id, s."database_name" AS database_name,
         s."schema_name" AS schema_name, s."owner" AS owner, s."warehouse" AS warehouse_name,
         s."schedule" AS schedule, TO_VARCHAR(s."predecessors") AS predecessors, s."state" AS state,
         s."created_on" AS created_on, s."last_suspended_on" AS last_suspended_on,
         s."last_suspended_reason" AS last_suspended_reason
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
  WHERE __WITH_SNOWFLAKE_TASKS__ OR COALESCE(s."database_name", 'SNOWFLAKE') <> 'SNOWFLAKE'
),
h AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         MAX(IFF(state NOT IN ('SKIPPED', 'SCHEDULED'), completed_time, NULL)) AS last_run_time,
         MAX_BY(state, IFF(state NOT IN ('SKIPPED', 'SCHEDULED', 'EXECUTING'), scheduled_time, NULL)) AS last_state,
         COUNT_IF(state NOT IN ('SKIPPED', 'SCHEDULED')) AS recent_runs
  FROM __SHIM_TASK_HISTORY__
  WHERE scheduled_time >= DATEADD(day, -(:stale_days + 1), __AS_OF_DATE__)
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
  GROUP BY 1
),
j AS (
  SELECT s.*, h.last_run_time, h.last_state, COALESCE(h.recent_runs, 0) AS recent_runs,
         DATEDIFF('day', s.last_suspended_on, __AS_OF_DATE__) AS days_suspended,
         DATEDIFF('day', s.created_on, __AS_OF_DATE__) AS days_since_created,
         -- SHOW returns predecessors as an ARRAY, made text above so an empty list compares as '[]'.
         (s.predecessors IS NULL OR s.predecessors IN ('', '[]')) AS is_root
  FROM shown s LEFT JOIN h ON h.task_full_name = s.task_full_name
),
classed AS (
  SELECT j.*,
         CASE
           -- TASK_HISTORY has no auto-suspend state; SHOW TASKS records why a task was last suspended.
           WHEN LOWER(state) = 'suspended' AND last_suspended_reason = 'SUSPENDED_DUE_TO_ERRORS' THEN 'auto_suspended_after_failures'
           WHEN LOWER(state) = 'started' AND recent_runs = 0 AND days_since_created > :stale_days
             THEN 'started_but_not_running'
           WHEN LOWER(state) = 'suspended' AND COALESCE(days_suspended, days_since_created) > :stale_days
             THEN IFF(last_suspended_on IS NULL, 'never_ran', 'suspended_stale')
           ELSE 'ok'
         END AS finding
  FROM j
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, owner,
       COALESCE(warehouse_name, 'SERVERLESS') AS compute, schedule, predecessors, is_root, state,
       created_on, last_suspended_on, days_suspended, last_run_time, recent_runs, last_state,
       :stale_days AS stale_days, finding,
       CASE finding
         WHEN 'auto_suspended_after_failures' THEN 'suspended by Snowflake after repeated failures'
         WHEN 'started_but_not_running' THEN IFF(is_root, 'started root with no run in ' || :stale_days || ' days: check the schedule',
                                                 'started child with no run in ' || :stale_days || ' days: check its root and predecessors')
         WHEN 'suspended_stale' THEN 'suspended for ' || days_suspended || ' days'
         WHEN 'never_ran' THEN 'created ' || days_since_created || ' days ago and never resumed'
         ELSE 'running' END AS stale_reason,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE finding
         WHEN 'auto_suspended_after_failures' THEN 'CRITICAL'
         WHEN 'ok' THEN 'OK'
         ELSE 'WARN'
       END AS status
FROM classed
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, task_full_name
