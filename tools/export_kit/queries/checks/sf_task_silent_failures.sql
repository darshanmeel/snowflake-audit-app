-- query_id: sf_task_silent_failures
-- title: Failing tasks with no one notified, and tasks set up to fail quietly
-- domain: jobs_pipelines   tier: standard
-- entity: root tasks = task_full_name
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASKS, SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.USERS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :crit_failed_runs (default 3) failed runs in the graph from which silent failures read CRITICAL
-- empty_if: role_cannot_see, view_missing, no_activity
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. That ACCOUNT_USAGE.TASKS lists tasks a limited role
--   cannot SHOW is taken from it being an object view under IMPORTED PRIVILEGES; the docs do not say.
-- not_assessed_reasons: tasks_not_visible: task runs exist in the window but the TASKS view has no rows, so
--   the setup of the tasks is not known (the role cannot see it)
-- read_this: one row = one live root task (a task with no predecessor, finalizers apart). failed_runs_in_graph
--   counts FAILED runs of any task in its graph in the window. finding is silent_failures (runs failed and
--   there is neither an error integration nor a finalizer task), execute_as_user_gone (it runs as a disabled
--   or deleted user, or one the view does not list), admin_owner (an admin role owns it), allow_all_overlap
--   (a warehouse task may start a second copy), or ok. Tasks Snowflake suspended after errors are judged in
--   sf_task_suspended_or_stale.
-- healthy: status = OK when failures reach someone, the run-as user is live and no admin role owns the task.
-- investigate_if: WARN when it failed fewer than :crit_failed_runs times with no error integration or finalizer,
--   an admin role owns it, or it allows all overlap on a warehouse; CRITICAL when it failed :crit_failed_runs
--   or more times with none, or runs as a user who is gone.
-- actions: 1) set ERROR_INTEGRATION on the root task (an email or queue notification integration), or add a
--   finalizer task that alerts (config); 2) ALTER TASK ... SET EXECUTE AS USER to a live service user, and
--   move ownership from an admin role to a task role (config); 3) resume a task suspended by errors once
--   the cause is fixed, see sf_task_suspended_or_stale (free).
-- next: sf_task_failures, sf_task_suspended_or_stale
-- caveats: A task that failed once and recovered still reads silent_failures if nothing was notified.
--   An alert or event-table monitor on the task is not seen here. Only the integration name is read, never
--   the task text or its config. A task graph is judged by its
--   root: an error integration set only on a child does not reach the graph's other tasks. Dropped tasks
--   are left out. TASK_HISTORY lags up to 45 minutes.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH t AS (
  SELECT TO_VARCHAR(id) AS task_id, task_database || '.' || task_schema || '.' || task_name AS task_full_name,
         task_owner, warehouse AS warehouse_name, schedule AS task_schedule, LOWER(state) AS state,
         error_integration, last_suspended, last_suspended_reason, UPPER(overlap_policy) AS overlap_policy,
         execute_as_user_id, task_relations:FinalizerTask IS NOT NULL AS has_finalizer
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASKS
  WHERE deleted IS NULL
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(task_database, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND COALESCE(ARRAY_SIZE(predecessors), 0) = 0 AND task_relations:FinalizedRootTask IS NULL
),
r AS (
  SELECT TO_VARCHAR(root_task_id) AS task_id, COUNT_IF(state = 'FAILED') AS failed_runs_in_graph
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
  GROUP BY 1
),
u AS (
  SELECT user_id, MAX(name) AS user_name,
         BOOLOR_AGG(deleted_on IS NOT NULL OR COALESCE(TRY_TO_BOOLEAN(TO_VARCHAR(disabled)), FALSE)) AS is_gone
  FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
  GROUP BY 1
),
s AS (
  SELECT t.*, COALESCE(r.failed_runs_in_graph, 0) AS failed_runs_in_graph,
         NULLIF(TRIM(t.error_integration), '') IS NOT NULL AS has_error_integration,
         t.state = 'started' AND t.execute_as_user_id IS NOT NULL AND COALESCE(u.is_gone, TRUE) AS run_as_gone,
         IFF(t.execute_as_user_id IS NULL, NULL,
             COALESCE(u.user_name, 'unknown user') || ' (' || TO_VARCHAR(t.execute_as_user_id) || ')') AS execute_as_user_name
  FROM t
  LEFT JOIN r ON r.task_id = t.task_id
  LEFT JOIN u ON u.user_id = t.execute_as_user_id
),
f AS (
  SELECT s.*,
         COALESCE(failed_runs_in_graph, 0) > 0 AND NOT has_error_integration AND NOT has_finalizer AS silent,
         UPPER(task_owner) IN ('ACCOUNTADMIN', 'SECURITYADMIN', 'ORGADMIN') AS admin_owner,
         COALESCE(overlap_policy = 'ALLOW_ALL_OVERLAP', FALSE) AND warehouse_name IS NOT NULL AS all_overlap
  FROM s
),
main AS (
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, task_full_name, task_id, task_owner, warehouse_name,
         task_schedule, state, failed_runs_in_graph, has_error_integration, error_integration, has_finalizer,
         last_suspended, last_suspended_reason, overlap_policy, execute_as_user_name,
         CASE WHEN silent THEN 'silent_failures' WHEN run_as_gone THEN 'execute_as_user_gone'
              WHEN admin_owner THEN 'admin_owner'
              WHEN all_overlap THEN 'allow_all_overlap' ELSE 'ok' END AS finding,
         ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
           IFF(silent, failed_runs_in_graph || ' failed runs and no error integration or finalizer', NULL),
           IFF(run_as_gone, 'runs as ' || execute_as_user_name || ', who is disabled or deleted', NULL),
           IFF(admin_owner, 'owned by ' || task_owner, NULL),
           IFF(all_overlap, 'allows all overlap on a warehouse task', NULL)), '; ') AS reasons,
         CAST(NULL AS VARCHAR) AS not_assessed_reason,
         CASE WHEN run_as_gone OR (silent AND failed_runs_in_graph >= :crit_failed_runs) THEN 'CRITICAL'
              WHEN silent OR admin_owner OR all_overlap THEN 'WARN'
              ELSE 'OK' END AS status
  FROM f
),
blind AS (
  -- Runs exist but the TASKS view lists nothing: the role cannot see the tasks, so say so.
  SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, CAST('(tasks not visible to this role)' AS VARCHAR) AS task_full_name,
         CAST(NULL AS VARCHAR) AS task_id, CAST(NULL AS VARCHAR) AS task_owner, CAST(NULL AS VARCHAR) AS warehouse_name,
         CAST(NULL AS VARCHAR) AS task_schedule, CAST(NULL AS VARCHAR) AS state, CAST(NULL AS NUMBER) AS failed_runs_in_graph,
         CAST(NULL AS BOOLEAN) AS has_error_integration, CAST(NULL AS VARCHAR) AS error_integration,
         CAST(NULL AS BOOLEAN) AS has_finalizer, CAST(NULL AS TIMESTAMP_LTZ) AS last_suspended,
         CAST(NULL AS VARCHAR) AS last_suspended_reason, CAST(NULL AS VARCHAR) AS overlap_policy,
         CAST(NULL AS VARCHAR) AS execute_as_user_name, CAST(NULL AS VARCHAR) AS finding, CAST(NULL AS VARCHAR) AS reasons,
         'tasks_not_visible' AS not_assessed_reason, 'NOT_ASSESSED' AS status
  WHERE NOT EXISTS (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.TASKS)
    AND EXISTS (SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
                WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__)
)
SELECT * FROM (
  SELECT * FROM main
  UNION ALL
  SELECT * FROM blind
)
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
         failed_runs_in_graph DESC NULLS LAST, task_full_name
