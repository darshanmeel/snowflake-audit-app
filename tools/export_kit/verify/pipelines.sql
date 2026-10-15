-- Test queries: Tasks & pipelines and Data loading. Read-only (SELECT and WITH only); paste one at a
-- time into a worksheet. Each recomputes a figure the app shows, straight from SNOWFLAKE.ACCOUNT_USAGE.
-- Change the numbers in the p CTE: days = the window you picked in the app, end_date = the export date
-- (the app counts up to midnight of that day; today is left out), usd_per_credit = your price.

-- 1. Task runs and failures per task (Tasks & pipelines; checks sf_task_failures and sf_task_runs_daily).
--    consecutive_failures = failed runs since the task's last success in the window.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
r AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task, state, scheduled_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, p
  WHERE scheduled_time >= DATEADD(day, -p.days, p.end_date) AND scheduled_time < p.end_date
    AND state NOT IN ('SCHEDULED', 'EXECUTING')
),
l AS (SELECT task, MAX(IFF(state = 'SUCCEEDED', scheduled_time, NULL)) AS last_success FROM r GROUP BY task)
SELECT r.task, COUNT_IF(r.state <> 'SKIPPED') AS runs, COUNT_IF(r.state = 'FAILED') AS failed_runs,
       COUNT_IF(r.state = 'SKIPPED') AS skipped_runs,
       COUNT_IF(r.state = 'FAILED' AND r.scheduled_time > COALESCE(l.last_success, '1970-01-01'::TIMESTAMP_LTZ)) AS consecutive_failures
FROM r JOIN l ON l.task = r.task
GROUP BY r.task
ORDER BY failed_runs DESC;

-- 2. What each task costs: its statements' warehouse credits plus serverless task credits
--    (Tasks & pipelines; check sf_task_cost).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date, 3.00 AS usd_per_credit),
r AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task, query_id
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, p
  WHERE scheduled_time >= DATEADD(day, -p.days, p.end_date) AND scheduled_time < p.end_date
    AND state NOT IN ('SCHEDULED', 'EXECUTING', 'SKIPPED')
),
a AS (
  SELECT COALESCE(root_query_id, query_id) AS task_query_id,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < DATEADD(day, 1, p.end_date)
  GROUP BY 1
),
w AS (SELECT r.task, COUNT(*) AS runs, SUM(COALESCE(a.credits, 0)) AS wh_credits FROM r LEFT JOIN a ON a.task_query_id = r.query_id GROUP BY r.task),
s AS (
  -- CREDITS_USED is VARCHAR in the docs but NUMBER on live accounts, so go through text
  SELECT database_name || '.' || schema_name || '.' || task_name AS task, SUM(TRY_TO_DOUBLE(TO_VARCHAR(credits_used))) AS serverless_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
  GROUP BY 1
)
SELECT COALESCE(w.task, s.task) AS task, COALESCE(w.runs, 0) AS runs,
       ROUND(COALESCE(w.wh_credits, 0) + COALESCE(s.serverless_credits, 0), 2) AS credits,
       ROUND((COALESCE(w.wh_credits, 0) + COALESCE(s.serverless_credits, 0)) * p.usd_per_credit, 2) AS usd
FROM w FULL OUTER JOIN s ON s.task = w.task CROSS JOIN p
ORDER BY credits DESC;

-- 3. Dynamic table refreshes, failures and credits (Tasks & pipelines; checks sf_dt_cost and
--    sf_dt_refresh_failures_and_lag).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date),
a AS (
  SELECT COALESCE(root_query_id, query_id) AS rq,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, p
  WHERE start_time >= DATEADD(day, -p.days - 1, p.end_date) AND start_time < DATEADD(day, 1, p.end_date)
  GROUP BY 1
)
SELECT r.database_name || '.' || r.schema_name || '.' || r.name AS dynamic_table, COUNT(*) AS refreshes,
       COUNT_IF(r.state = 'FAILED') AS failed, COUNT_IF(r.state = 'UPSTREAM_FAILED') AS upstream_failed,
       ROUND(SUM(COALESCE(a.credits, 0)), 2) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY r
LEFT JOIN a ON a.rq = r.query_id, p
WHERE r.data_timestamp >= DATEADD(day, -p.days, p.end_date) AND r.data_timestamp < p.end_date
  AND r.state NOT IN ('SCHEDULED', 'EXECUTING')
GROUP BY 1
ORDER BY credits DESC;

-- 4. Snowpipe credits and files per pipe (Data loading; check sf_pipe_cost_and_files). A row with no
--    pipe id is Snowflake's internal pipe that auto-refreshes external and directory tables.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT COALESCE(MAX(pipe_name), '(external table auto-refresh)') || ' (' || COALESCE(TO_VARCHAR(pipe_id), '-') || ')' AS pipe,
       ROUND(SUM(credits_used), 3) AS credits, SUM(TRY_TO_DOUBLE(TO_VARCHAR(files_inserted))) AS files,
       ROUND(SUM(bytes_inserted) / POWER(1024, 3), 2) AS gb
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
GROUP BY pipe_id
ORDER BY credits DESC;

-- 5. Load files that failed or partly loaded, per table and loader (Data loading; check
--    sf_load_copy_errors). Only tables with an error are listed, as on the page.
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT table_catalog_name || '.' || table_schema_name || '.' || table_name AS target_table, pipe_name,
       COUNT(*) AS files, COUNT_IF(UPPER(status) LIKE '%FAIL%') AS failed_files,
       COUNT_IF(UPPER(status) LIKE '%PARTIAL%') AS partial_files, SUM(COALESCE(error_count, 0)) AS rows_rejected
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY, p
WHERE last_load_time >= DATEADD(day, -p.days, p.end_date) AND last_load_time < p.end_date
GROUP BY table_id, 1, 2
HAVING failed_files + partial_files > 0 OR rows_rejected > 0
ORDER BY failed_files DESC;

-- 6. Replication and failover credits held in this account (Data loading; check sf_repl_group_health).
WITH p AS (SELECT 30 AS days, CURRENT_DATE() AS end_date)
SELECT 'groups' AS kind, ROUND(SUM(credits_used), 3) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date
UNION ALL
SELECT 'legacy databases', ROUND(SUM(credits_used), 3)
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_REPLICATION_USAGE_HISTORY, p
WHERE start_time >= DATEADD(day, -p.days, p.end_date) AND start_time < p.end_date;
