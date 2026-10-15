-- query_id: sf_stream_consumers
-- shims: TASK_HISTORY
-- reads: INFORMATION_SCHEMA table functions TASK_HISTORY
-- fallback_note: task runs for the last 7 days at most, up to 10,000 a day, only tasks this role owns or can monitor (MONITOR EXECUTION shows all)
-- pre: SHOW STREAMS IN ACCOUNT; SHOW TASKS IN ACCOUNT
WITH s AS (
  SELECT "database_name" AS database_name, "schema_name" AS schema_name, "name" AS stream_name,
         "database_name" || '.' || "schema_name" || '.' || "name" AS stream_fqn,
         LOWER(TO_VARCHAR("stale")) = 'true' AS is_stale,
         CAST("stale_after" AS TIMESTAMP_LTZ) AS stale_after
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-2)))
),
t AS (
  SELECT "database_name" AS database_name, "schema_name" AS schema_name, "name" AS task_name,
         "database_name" || '.' || "schema_name" || '.' || "name" AS task_fqn,
         LOWER("state") AS task_state, "warehouse" AS task_warehouse,
         UPPER(REPLACE(COALESCE("condition", '') || ' ' || COALESCE("definition", ''), '"', '')) AS task_text,
         CONTAINS(UPPER(COALESCE("condition", '')), 'STREAM_HAS_DATA') AS has_stream_condition
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
),
link AS (
  SELECT s.stream_fqn, t.task_fqn, t.task_state, t.has_stream_condition
  FROM s JOIN t
    ON CONTAINS(t.task_text, UPPER(s.schema_name || '.' || s.stream_name))
    OR (t.database_name = s.database_name AND t.schema_name = s.schema_name
        AND CONTAINS(t.task_text, UPPER(s.stream_name)))
),
runs AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_fqn, state, scheduled_time
  FROM __SHIM_TASK_HISTORY__
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND state NOT IN ('SCHEDULED', 'EXECUTING', 'SKIPPED')
),
task_runs AS (
  SELECT task_fqn,
         COUNT(*) AS runs,
         COUNT_IF(state = 'FAILED') AS failed_runs,
         MAX(IFF(state = 'SUCCEEDED', scheduled_time, NULL)) AS last_success_time,
         MAX_BY(state, scheduled_time) AS last_state
  FROM runs GROUP BY task_fqn
),
task_streak AS (
  SELECT r.task_fqn, COUNT(*) AS consecutive_failures
  FROM runs r JOIN task_runs tr ON tr.task_fqn = r.task_fqn
  WHERE r.state = 'FAILED'
    AND r.scheduled_time > COALESCE(tr.last_success_time, '1970-01-01'::TIMESTAMP_LTZ)
  GROUP BY r.task_fqn
),
agg AS (
  SELECT l.stream_fqn,
         COUNT(*) AS consumer_count,
         LISTAGG(l.task_fqn || ' (' || l.task_state || ')', ', ') WITHIN GROUP (ORDER BY l.task_fqn) AS consumer_tasks,
         COUNT_IF(l.task_state = 'started') AS started_consumers,
         COUNT_IF(l.task_state <> 'started') AS suspended_consumers,
         COUNT_IF(l.has_stream_condition) AS consumers_with_has_data_condition,
         SUM(COALESCE(tr.runs, 0)) AS runs,
         SUM(COALESCE(tr.failed_runs, 0)) AS failed_runs,
         MAX(COALESCE(ts.consecutive_failures, 0)) AS consecutive_failures,
         COUNT_IF(tr.last_state = 'FAILED') AS consumers_last_run_failed,
         MAX(tr.last_success_time) AS last_success_time
  FROM link l
  LEFT JOIN task_runs tr ON tr.task_fqn = l.task_fqn
  LEFT JOIN task_streak ts ON ts.task_fqn = l.task_fqn
  GROUP BY l.stream_fqn
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       s.stream_fqn, s.stream_name, s.database_name, s.schema_name, s.is_stale, s.stale_after,
       ROUND(DATEDIFF(minute, LEAST(CURRENT_TIMESTAMP(), CAST(__AS_OF_DATE__ AS TIMESTAMP)), s.stale_after) / 1440, 1) AS days_to_stale,
       a.consumer_count, a.consumer_tasks, a.started_consumers, a.suspended_consumers,
       a.consumers_with_has_data_condition, a.runs, a.failed_runs, a.consecutive_failures,
       a.consumers_last_run_failed, a.last_success_time,
       ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
         IFF(s.is_stale, 'stream is stale', NULL),
         IFF(a.started_consumers = 0, 'every consuming task is suspended', NULL),
         IFF(a.started_consumers > 0 AND a.suspended_consumers > 0, a.suspended_consumers || ' consumer(s) suspended', NULL),
         IFF(a.consumers_last_run_failed > 0, a.consumers_last_run_failed || ' consumer(s) failed on the latest run', NULL),
         IFF(a.consecutive_failures > 0, a.consecutive_failures || ' failures in a row', NULL)), '; ') AS reasons,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN s.is_stale OR a.started_consumers = 0 OR a.consecutive_failures >= :crit_consecutive_failures
           OR DATEDIFF(minute, LEAST(CURRENT_TIMESTAMP(), CAST(__AS_OF_DATE__ AS TIMESTAMP)), s.stale_after) / 1440 <= :crit_days_to_stale THEN 'CRITICAL'
         WHEN a.suspended_consumers > 0 OR a.consumers_last_run_failed > 0 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s JOIN agg a ON a.stream_fqn = s.stream_fqn
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, s.stale_after NULLS LAST
