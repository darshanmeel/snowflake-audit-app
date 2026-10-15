-- query_id: sf_task_noop_runs
-- title: Task runs that wake a warehouse and change nothing
-- domain: jobs_pipelines   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS,
--   SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :min_runs (default 10) runs: least judged runs a task needs before it can flag; :warn_noop_pct
--   (default 50) noop pct: at or above this share of judged runs the row can read WARN; :crit_noop_pct
--   (default 90) noop pct: at or above this the row can read CRITICAL; :warn_usd (default 5) usd: least
--   no-op cost for WARN; :crit_usd (default 50) usd: least no-op cost for CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one task with succeeded runs in the window. A run is a no-op when its attributed
--   statements inserted, updated, deleted and unloaded no rows; it is changed when they did, and unknown
--   when a statement is missing from attribution or query history, or is not a plain row-changing
--   statement. noop_pct is no-op runs of those judged. est_wasted_usd_list is at least what no-op runs
--   cost, from per-query attribution.
-- healthy: status = OK when few runs are no-ops, the no-op cost is small, or too few runs could be judged.
-- investigate_if: WARN when noop_pct >= warn_noop_pct and no-op cost >= warn_usd; CRITICAL when
--   noop_pct >= crit_noop_pct and no-op cost >= crit_usd.
-- actions: 1) add a WHEN condition such as SYSTEM$STREAM_HAS_DATA so the task skips the run without
--   waking the warehouse (free); 2) schedule it less often (free); 3) move a stream-driven task to
--   serverless so it bills only for real work (config).
-- next: sf_task_cost
-- empty_if: no_activity, ingestion_lag
-- not_assessed_reasons: unpriced: no credit price is available for the window, so the no-op cost cannot
--   be priced; no_attributed_statements: no run of the task has statements in query attribution (a
--   serverless task, an adaptive warehouse, or statements under about 100 ms), so nothing can be judged
-- caveats: it reads that no rows changed in the attributed statements, not that nothing happened: DDL,
--   COPY loads, external calls and notifications are not row counts, and such runs are unknown. Query
--   attribution leaves out idle time and queries under about 100 ms, is empty on adaptive warehouses and
--   lags up to 8 hours, so cost is a floor. Serverless tasks have no attribution and show run counts
--   only. The task SQL and WHEN text are not stored.
--   Snowflake's own tasks (SNOWFLAKE database, or none: Trust Center, cost anomalies, Cortex) are left out; set
--   include_snowflake_tasks: true in config/settings.yml to show them. Their credits stay in sf_task_cost.
WITH __INCLUDE_sf_task_dim__,
runs AS (
  SELECT database_name || '.' || schema_name || '.' || name AS task_full_name,
         name AS task_name, database_name, schema_name, query_id,
         condition_text IS NOT NULL AS has_condition
  FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
  WHERE scheduled_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND scheduled_time < __AS_OF_DATE__
    AND (__WITH_SNOWFLAKE_TASKS__ OR COALESCE(database_name, 'SNOWFLAKE') <> 'SNOWFLAKE')
    AND state = 'SUCCEEDED' AND query_id IS NOT NULL
),
-- Child statements of a procedure carry the task's query id as root_query_id.
attr AS (
  SELECT query_id AS stmt_id, COALESCE(root_query_id, query_id) AS task_query_id,
         credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < DATEADD(day, 1, __AS_OF_DATE__)
),
run_stats AS (
  SELECT r.task_full_name, r.task_name, r.database_name, r.schema_name, r.query_id, r.has_condition,
         COUNT(a.stmt_id) AS stmts,
         COUNT(q.query_id) AS stmts_with_history,
         COUNT_IF(q.query_type NOT IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'CALL', 'UNLOAD')) AS other_stmts,
         SUM(COALESCE(a.credits, 0)) AS credits,
         SUM(COALESCE(q.rows_inserted, 0) + COALESCE(q.rows_updated, 0) + COALESCE(q.rows_deleted, 0)
             + COALESCE(q.rows_unloaded, 0)) AS rows_changed
  FROM runs r
  LEFT JOIN attr a ON a.task_query_id = r.query_id
  LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    ON q.query_id = a.stmt_id
   AND q.start_time >= DATEADD(day, -:period_days - 1, __AS_OF_DATE__) AND q.start_time < DATEADD(day, 1, __AS_OF_DATE__)
  GROUP BY r.task_full_name, r.task_name, r.database_name, r.schema_name, r.query_id, r.has_condition
),
classed AS (
  SELECT run_stats.*,
         CASE WHEN stmts = 0 OR stmts_with_history < stmts OR other_stmts > 0 THEN 'unknown'
              WHEN rows_changed = 0 THEN 'noop'
              ELSE 'changed' END AS run_class
  FROM run_stats
),
t AS (
  SELECT task_full_name, MAX(task_name) AS task_name, MAX(database_name) AS database_name,
         MAX(schema_name) AS schema_name,
         COUNT(*) AS succeeded_runs,
         COUNT_IF(run_class = 'noop') AS noop_runs,
         COUNT_IF(run_class = 'changed') AS changed_runs,
         COUNT_IF(run_class = 'unknown') AS unknown_runs,
         COUNT_IF(stmts > 0) AS attributed_runs,
         COUNT_IF(has_condition) AS runs_with_when,
         SUM(IFF(run_class = 'noop', credits, 0)) AS noop_credits
  FROM classed
  GROUP BY task_full_name
),
s AS (
  SELECT t.*, d.task_id, d.task_warehouse_name,
         100 * noop_runs / NULLIF(noop_runs + changed_runs, 0) AS noop_pct,
         noop_credits * __CREDIT_PRICE__ AS usd
  FROM t LEFT JOIN sf_task_dim d ON d.task_full_name = t.task_full_name
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id,
       task_full_name, task_name, task_id, database_name, schema_name,
       task_warehouse_name AS warehouse_name,
       succeeded_runs, noop_runs, changed_runs, unknown_runs, runs_with_when,
       ROUND(noop_pct, 1) AS noop_pct, noop_credits,
       usd AS est_wasted_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       noop_runs || ' of ' || (noop_runs + changed_runs) || ' judged runs changed no rows' AS waste_reason,
       CASE WHEN __CREDIT_PRICE__ IS NULL THEN 'unpriced'
            WHEN attributed_runs = 0 THEN 'no_attributed_statements' END AS not_assessed_reason,
       CASE
         WHEN __CREDIT_PRICE__ IS NULL OR attributed_runs = 0 THEN 'NOT_ASSESSED'
         WHEN noop_runs + changed_runs < :min_runs THEN 'OK'
         WHEN noop_pct >= :crit_noop_pct AND usd >= :crit_usd THEN 'CRITICAL'
         WHEN noop_pct >= :warn_noop_pct AND usd >= :warn_usd THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM s
ORDER BY est_wasted_usd_list DESC NULLS LAST, noop_runs DESC
