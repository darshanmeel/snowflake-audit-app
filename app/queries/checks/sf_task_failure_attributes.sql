-- query_id: sf_task_failure_attributes
-- title: Failed task runs vs all runs, by attribute
-- domain: jobs_pipelines   tier: standard
-- entity: attribute values = scope, task_full_name, attribute, attr_value
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS,
--   SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- empty_if: role_cannot_see, no_activity
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = one value of one attribute of task runs, for a scope. scope = 'all' is every task
--   run in the account; scope = 'task' is one task that failed at least once (task_full_name). runs and
--   failed_runs count that value's runs (skipped runs did not run and are left out); pct_of_failed is its
--   share of the scope's failed runs and pct_of_runs its share of all the scope's runs. A value far more
--   common among failed runs than among all runs is where failures gather. Attributes: compute (the
--   warehouse, or serverless), owner_role, schedule, graph_position (root or child), database, trigger
--   (SCHEDULED_FROM), attempt (first try or retry), hour_utc and weekday (ISO, 1 = Monday).
-- healthy: n/a - inventory (the per-task verdict is sf_task_failures)
-- investigate_if: n/a - inventory; read pct_of_failed against pct_of_runs
-- actions: n/a - inventory, nothing to act on; see sf_task_failures
-- next: sf_task_failures
-- caveats: compute, owner_role and schedule come from the task's latest definition in TASK_VERSIONS, not
--   from each run; a task changed in the window shows its current settings on all its runs. The warehouse
--   id is looked up by name in WAREHOUSE_METERING_HISTORY. TASK_HISTORY lags up to 45 minutes.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH __INCLUDE_sf_task_dim__,
own AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         MAX_BY(owner, last_committed_on) AS owner_role
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
  GROUP BY 1
),
wh_ids AS (
  SELECT warehouse_name, TO_VARCHAR(MAX(warehouse_id)) AS warehouse_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
runs AS (
  SELECT h.database_name || '.' || h.schema_name || '.' || h.name AS task_full_name,
         h.database_name, h.state = 'FAILED' AS is_failed, h.scheduled_time,
         COALESCE(h.scheduled_from, 'unknown') AS scheduled_from,
         IFF(COALESCE(h.attempt_number, 1) > 1, 'retry', 'first try') AS attempt,
         TO_VARCHAR(h.root_task_id) AS root_task_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY h
  WHERE h.scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND h.scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(h.database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND h.state IN ('SUCCEEDED', 'FAILED', 'CANCELLED')
),
r AS (
  SELECT r.task_full_name, r.is_failed, d.task_id,
         COALESCE(d.task_warehouse_name, IFF(d.task_id IS NULL, 'unknown', 'serverless')) AS compute_name,
         w.warehouse_id AS compute_id,
         COALESCE(o.owner_role, 'unknown') AS owner_role,
         COALESCE(d.task_schedule, IFF(d.task_id IS NULL, 'unknown', 'none (runs after its predecessor)')) AS schedule,
         IFF(r.root_task_id IS NULL OR d.task_id IS NULL, 'unknown',
             IFF(r.root_task_id = d.task_id, 'root task', 'child task')) AS graph_position,
         r.database_name, r.scheduled_from, r.attempt,
         LPAD(TO_VARCHAR(HOUR(r.scheduled_time)), 2, '0') || ':00' AS hour_utc,
         TO_VARCHAR(DAYOFWEEKISO(r.scheduled_time)) AS weekday
  FROM runs r
  LEFT JOIN sf_task_dim d ON d.task_full_name = r.task_full_name
  LEFT JOIN own o ON o.task_full_name = r.task_full_name
  LEFT JOIN wh_ids w ON w.warehouse_name = d.task_warehouse_name
),
failing AS (
  SELECT task_full_name FROM r GROUP BY 1 HAVING COUNT_IF(is_failed) > 0
),
-- One row per run and attribute; the per-task scope repeats the failing tasks' runs.
attrs AS (
  SELECT x.scope, x.scope_task, x.scope_task_id, x.is_failed, a.attribute,
         CASE a.attribute WHEN 'compute' THEN x.compute_name WHEN 'owner_role' THEN x.owner_role
              WHEN 'schedule' THEN x.schedule WHEN 'graph_position' THEN x.graph_position
              WHEN 'database' THEN x.database_name WHEN 'trigger' THEN x.scheduled_from
              WHEN 'attempt' THEN x.attempt WHEN 'hour_utc' THEN x.hour_utc ELSE x.weekday END AS attr_value,
         IFF(a.attribute = 'compute', x.compute_id, NULL) AS attr_id
  FROM (
    SELECT 'all' AS scope, CAST(NULL AS VARCHAR) AS scope_task, CAST(NULL AS VARCHAR) AS scope_task_id, r.* FROM r
    UNION ALL
    SELECT 'task', r.task_full_name, r.task_id, r.* FROM r JOIN failing f ON f.task_full_name = r.task_full_name
  ) x
  CROSS JOIN (VALUES ('compute'), ('owner_role'), ('schedule'), ('graph_position'), ('database'), ('trigger'),
                     ('attempt'), ('hour_utc'), ('weekday')) a (attribute)
),
g AS (
  SELECT scope, scope_task, MAX(scope_task_id) AS scope_task_id, attribute, attr_value, MAX(attr_id) AS attr_id,
         COUNT(*) AS runs, COUNT_IF(is_failed) AS failed_runs
  FROM attrs
  GROUP BY scope, scope_task, attribute, attr_value
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, g.scope,
       g.scope_task AS task_full_name, g.scope_task_id AS task_id, g.attribute, g.attr_value, g.attr_id,
       g.runs, g.failed_runs,
       SUM(g.runs) OVER (PARTITION BY g.scope, g.scope_task, g.attribute) AS scope_runs,
       SUM(g.failed_runs) OVER (PARTITION BY g.scope, g.scope_task, g.attribute) AS scope_failed_runs,
       100 * g.failed_runs / NULLIF(SUM(g.failed_runs) OVER (PARTITION BY g.scope, g.scope_task, g.attribute), 0) AS pct_of_failed,
       100 * g.runs / NULLIF(SUM(g.runs) OVER (PARTITION BY g.scope, g.scope_task, g.attribute), 0) AS pct_of_runs
FROM g
ORDER BY g.scope, g.scope_task, g.attribute, g.failed_runs DESC, g.runs DESC
