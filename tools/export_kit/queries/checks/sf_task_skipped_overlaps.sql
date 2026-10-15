-- query_id: sf_task_skipped_overlaps
-- title: Task runs skipped because the last run was still going
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_skip_pct (default 10) skip pct: at or above this the row reads WARN; :crit_skip_pct
--   (default 30) skip pct: at or above this the row reads CRITICAL; :warn_duration_to_interval_pct
--   (default 80) duration to interval pct: at or above this the row reads WARN; :min_scheduled_runs
--   (default 5) scheduled runs: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task that had SKIPPED runs or ran close to its interval. overlap_skips are
--   skipped runs that were not a WHEN condition evaluating false: with ALLOW_OVERLAPPING_EXECUTION off,
--   Snowflake skips a run while the previous one is still executing. median_interval_seconds is the
--   typical gap between scheduled runs; p90_duration_to_interval_pct compares slow runs to that gap.
-- healthy: status = OK when under warn_skip_pct of scheduled runs are skipped and p90 runs finish well
--   inside the interval.
-- investigate_if: WARN when skip_pct >= warn_skip_pct or p90_duration_to_interval_pct >=
--   warn_duration_to_interval_pct; CRITICAL when skip_pct >= crit_skip_pct.
-- actions: 1) widen the SCHEDULE to match how long the task really takes (free); 2) make the work
--   incremental so each run is shorter (free); 3) give the task more compute (bigger warehouse or
--   serverless size) (spend).
-- next: none
-- caveats: the split between overlap and condition skips reads error_message text, so it is a best
--   effort; last_skip_message shows the real text. Child tasks in a graph run when their parents
--   finish, so their interval is the graph's. TASK_HISTORY lags up to 45 minutes.
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
         name AS task_name, database_name, schema_name, state, error_message, condition_text,
         scheduled_time,
         DATEDIFF('millisecond', query_start_time, completed_time) / 1000 AS duration_seconds,
         state = 'SKIPPED' AND NOT (condition_text IS NOT NULL
           AND (COALESCE(error_message, '') ILIKE ANY ('%condition%', '%stream%'))) AS is_overlap_skip,
         state = 'SKIPPED' AND condition_text IS NOT NULL
           AND COALESCE(error_message, '') ILIKE ANY ('%condition%', '%stream%') AS is_condition_skip
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
),
gaps AS (
  SELECT task_full_name,
         DATEDIFF('second', LAG(scheduled_time) OVER (PARTITION BY task_full_name ORDER BY scheduled_time),
                  scheduled_time) AS gap_seconds
  FROM (SELECT DISTINCT task_full_name, scheduled_time FROM runs)
),
g AS (
  SELECT task_full_name, MEDIAN(gap_seconds) AS median_interval_seconds
  FROM gaps WHERE gap_seconds > 0 GROUP BY 1
),
t AS (
  SELECT task_full_name, MAX(task_name) AS task_name, MAX(database_name) AS database_name,
         MAX(schema_name) AS schema_name,
         COUNT(*) AS scheduled_runs,
         COUNT_IF(state <> 'SKIPPED') AS executed_runs,
         COUNT_IF(is_overlap_skip) AS overlap_skips,
         COUNT_IF(is_condition_skip) AS condition_skips,
         MEDIAN(IFF(state = 'SUCCEEDED', duration_seconds, NULL)) AS p50_duration_seconds,
         APPROX_PERCENTILE(IFF(state = 'SUCCEEDED', duration_seconds, NULL), 0.9) AS p90_duration_seconds,
         MAX(IFF(state = 'SUCCEEDED', duration_seconds, NULL)) AS max_duration_seconds,
         MAX(IFF(is_overlap_skip, scheduled_time, NULL)) AS last_skip_time,
         MAX_BY(error_message, IFF(is_overlap_skip, scheduled_time, NULL)) AS last_skip_message
  FROM runs GROUP BY 1
),
scored AS (
  SELECT t.*, g.median_interval_seconds, d.task_id, d.root_task_id, d.root_task_full_name, d.task_schedule,
         100 * overlap_skips / NULLIF(scheduled_runs - condition_skips, 0) AS skip_pct,
         100 * p90_duration_seconds / NULLIF(g.median_interval_seconds, 0) AS p90_duration_to_interval_pct
  FROM t
  LEFT JOIN g ON g.task_full_name = t.task_full_name
  LEFT JOIN sf_task_dim d ON d.task_full_name = t.task_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, root_task_id, root_task_full_name,
       SPLIT_PART(root_task_full_name, '.', 3) AS root_task_name,
       task_schedule, scheduled_runs, executed_runs, overlap_skips, condition_skips, skip_pct,
       median_interval_seconds, p50_duration_seconds, p90_duration_seconds, max_duration_seconds,
       p90_duration_to_interval_pct, last_skip_time, LEFT(last_skip_message, 300) AS last_skip_message,
       overlap_skips || ' of ' || scheduled_runs || ' scheduled runs skipped; p90 run '
         || ROUND(p90_duration_seconds) || ' s vs interval ' || ROUND(median_interval_seconds) || ' s'
         AS skip_reason,
       CASE WHEN scheduled_runs < :min_scheduled_runs THEN 'too_few_runs' END AS not_assessed_reason,
       CASE
         WHEN scheduled_runs < :min_scheduled_runs THEN 'NOT_ASSESSED'
         WHEN skip_pct >= :crit_skip_pct THEN 'CRITICAL'
         WHEN skip_pct >= :warn_skip_pct
           OR p90_duration_to_interval_pct >= :warn_duration_to_interval_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
WHERE overlap_skips > 0 OR p90_duration_to_interval_pct >= :warn_duration_to_interval_pct / 2
ORDER BY overlap_skips DESC, p90_duration_to_interval_pct DESC NULLS LAST
