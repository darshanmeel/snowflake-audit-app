-- query_id: sf_task_cost
-- title: What each task costs
-- domain: jobs_pipelines   tier: standard
-- money: est_task_usd_list
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_usd (default 50) usd: at or above this the row reads WARN; :crit_usd (default 500) usd:
--   at or above this the row reads CRITICAL; :warn_growth_pct (default 50) growth pct: at or above this
--   the row reads WARN; :min_growth_usd (default 10) growth usd: least a row needs before it can flag
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task. serverless_credits come from SERVERLESS_TASK_HISTORY;
--   warehouse_credits are the per-query credits of the task's run (and of every statement a procedure
--   it calls runs, matched by root_query_id) from QUERY_ATTRIBUTION_HISTORY. prev_* is the same-length
--   window before.
-- healthy: status = OK when the task costs under warn_usd and did not grow by warn_growth_pct.
-- investigate_if: WARN when est_task_usd_list >= warn_usd, or it grew >= warn_growth_pct and by at
--   least min_growth_usd; CRITICAL when est_task_usd_list >= crit_usd.
-- actions: 1) run the task less often, or only WHEN SYSTEM$STREAM_HAS_DATA (free); 2) make the SQL
--   incremental (streams, MERGE on changed rows) instead of full rebuilds (free); 3) right-size the
--   task warehouse or serverless initial size (config).
-- next: none
-- caveats: warehouse credits exclude warehouse idle time and queries under ~100 ms (see
--   sf_task_warehouse_vs_serverless for idle). Serverless credits are billed per hour bucket and can
--   land slightly outside the window of the run. Cloud-services credits are not included.
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
         name AS task_name, database_name, schema_name, query_id,
         IFF(scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), 'current', 'previous') AS period
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND state NOT IN ('SCHEDULED', 'EXECUTING', 'SKIPPED')
),
-- Child statements of a procedure carry the task's query id as root_query_id.
attr AS (
  SELECT COALESCE(root_query_id, query_id) AS task_query_id, MAX(warehouse_name) AS warehouse_name,
         SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY 1
),
wh AS (
  SELECT r.task_full_name, MAX(r.task_name) AS task_name, MAX(r.database_name) AS database_name,
         MAX(r.schema_name) AS schema_name,
         COUNT_IF(r.period = 'current') AS runs,
         SUM(IFF(r.period = 'current', a.credits, 0)) AS warehouse_credits,
         SUM(IFF(r.period = 'previous', a.credits, 0)) AS prev_warehouse_credits,
         MAX(a.warehouse_name) AS warehouse_name
  FROM runs r LEFT JOIN attr a ON a.task_query_id = r.query_id
  GROUP BY r.task_full_name
),
sl AS (
  SELECT database_name || '.' || schema_name || '.' || task_name AS task_full_name,
         MAX(task_name) AS task_name, MAX(database_name) AS database_name, MAX(schema_name) AS schema_name,
         MAX(TO_VARCHAR(task_id)) AS task_id,
         SUM(IFF(start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__), TRY_TO_DOUBLE(TO_VARCHAR(credits_used)), 0)) AS serverless_credits,
         SUM(IFF(start_time < DATEADD(day, -:period_days, __AS_OF_DATE__), TRY_TO_DOUBLE(TO_VARCHAR(credits_used)), 0)) AS prev_serverless_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
  WHERE start_time >= DATEADD(day, -2 * :period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
j AS (
  SELECT COALESCE(wh.task_full_name, sl.task_full_name) AS task_full_name,
         COALESCE(wh.task_name, sl.task_name) AS task_name,
         COALESCE(sl.task_id, d.task_id) AS task_id,
         COALESCE(wh.database_name, sl.database_name) AS database_name,
         COALESCE(wh.schema_name, sl.schema_name) AS schema_name,
         d.root_task_id, d.root_task_full_name,
         COALESCE(wh.runs, 0) AS runs,
         COALESCE(wh.warehouse_name, d.task_warehouse_name) AS warehouse_name,
         COALESCE(wh.warehouse_credits, 0) AS warehouse_credits,
         COALESCE(sl.serverless_credits, 0) AS serverless_credits,
         COALESCE(wh.prev_warehouse_credits, 0) + COALESCE(sl.prev_serverless_credits, 0) AS prev_credits
  FROM wh
  FULL OUTER JOIN sl ON sl.task_full_name = wh.task_full_name
  LEFT JOIN sf_task_dim d ON d.task_full_name = COALESCE(wh.task_full_name, sl.task_full_name)
),
scored AS (
  SELECT j.*, warehouse_credits + serverless_credits AS credits,
         (warehouse_credits + serverless_credits) * __CREDIT_PRICE__ AS usd,
         prev_credits * __CREDIT_PRICE__ AS prev_usd
  FROM j
  WHERE warehouse_credits + serverless_credits + prev_credits > 0 OR runs > 0
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name, root_task_id, root_task_full_name,
       SPLIT_PART(root_task_full_name, '.', 3) AS root_task_name,
       CASE WHEN serverless_credits > 0 AND warehouse_credits > 0 THEN 'both'
            WHEN serverless_credits > 0 OR warehouse_name IS NULL THEN 'serverless'
            ELSE 'warehouse' END AS compute_kind,
       warehouse_name, runs, warehouse_credits, serverless_credits, credits, prev_credits,
       credits - prev_credits AS change_credits,
       usd AS est_task_usd_list, prev_usd AS est_prev_usd_list, usd - prev_usd AS est_change_usd_list,
       100 * (credits - prev_credits) / NULLIF(prev_credits, 0) AS change_pct,
       usd / NULLIF(runs, 0) AS est_usd_per_run,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       ROUND(credits, 2) || ' credits over ' || runs || ' runs (previous window '
         || ROUND(prev_credits, 2) || ')' AS cost_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL THEN 'NOT_ASSESSED'
         WHEN usd >= :crit_usd THEN 'CRITICAL'
         WHEN usd >= :warn_usd THEN 'WARN'
         WHEN usd - prev_usd >= :min_growth_usd
           AND 100 * (credits - prev_credits) / NULLIF(prev_credits, 0) >= :warn_growth_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM scored
ORDER BY est_task_usd_list DESC NULLS LAST, credits DESC
