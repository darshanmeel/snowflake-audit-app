-- query_id: sf_query_long_running
-- title: Long-running statements and missing statement timeouts
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY, SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_hours (default 1) hours: at or above this the row reads WARN; :crit_hours (default 8)
--   hours: at or above this the row reads CRITICAL; :crit_credits (default 100) credits: at or above
--   this the row reads CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: one row = one statement shape (query_parameterized_hash) on one warehouse with at least
--   one run of warn_hours or more. max_hours = longest run; timed_out_runs = runs ended by a statement
--   timeout (error 000630), which shows a timeout is set somewhere; runs past 24 h suggest none is.
-- healthy: status = OK never appears; a row exists only for statements past warn_hours
-- investigate_if: WARN for any run >= warn_hours; CRITICAL when a run >= crit_hours or the long runs
--   used >= crit_credits
-- actions: 1) ALTER WAREHOUSE ... SET STATEMENT_TIMEOUT_IN_SECONDS (default is 172800 = 2 days) on
--   warehouses running these (config); 2) tune the statement (filters, clustering, joins) or move it to
--   a bigger warehouse (free, config); 3) cancel runaways with SYSTEM$CANCEL_QUERY (free)
-- next: none
-- caveats: the timeout setting itself is per object (SHOW PARAMETERS IN WAREHOUSE) and is not read
--   here. Elapsed time includes queueing and compilation. Credits exclude idle time and lag up to 8
--   hours.
WITH qh AS (
  SELECT query_id, query_parameterized_hash, TO_VARCHAR(warehouse_id) AS warehouse_id, warehouse_name,
         warehouse_size, user_name, role_name, query_type, execution_status, error_code, start_time,
         total_elapsed_time / 3600000 AS elapsed_hours,
         execution_time / 3600000 AS exec_hours
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND total_elapsed_time >= :warn_hours * 3600000
),
attr AS (
  SELECT query_id, SUM(credits_attributed_compute + COALESCE(credits_used_query_acceleration, 0)) AS credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
  GROUP BY 1
),
g AS (
  SELECT qh.query_parameterized_hash, qh.warehouse_id, MAX(qh.warehouse_name) AS warehouse_name,
         MAX(qh.warehouse_size) AS warehouse_size, MAX(qh.query_type) AS query_type,
         COUNT(*) AS long_runs, MAX(qh.elapsed_hours) AS max_hours, SUM(qh.elapsed_hours) AS total_hours,
         SUM(qh.exec_hours) AS exec_hours,
         -- IFF, not COUNT_IF: a group with no error codes reads 0, not NULL
         SUM(IFF(qh.error_code = '000630', 1, 0)) AS timed_out_runs,
         COUNT_IF(qh.execution_status = 'FAIL') AS failed_runs,
         COUNT_IF(qh.elapsed_hours >= 24) AS runs_over_24h,
         ARRAY_TO_STRING(ARRAY_SLICE(ARRAY_AGG(DISTINCT qh.user_name), 0, 10), ', ') AS users,
         MAX_BY(qh.query_id, qh.elapsed_hours) AS longest_query_id,
         MIN(qh.start_time) AS first_seen, MAX(qh.start_time) AS last_seen,
         SUM(a.credits) AS credits
  FROM qh LEFT JOIN attr a ON a.query_id = qh.query_id
  GROUP BY qh.query_parameterized_hash, qh.warehouse_id
)
SELECT :period_days AS window_days, __ACCOUNT_ID__ AS account_id, warehouse_id, warehouse_name,
       warehouse_size, query_parameterized_hash, query_type, long_runs, max_hours, total_hours, exec_hours,
       timed_out_runs, failed_runs, runs_over_24h, users, longest_query_id,
       first_seen, last_seen, credits, credits * __CREDIT_PRICE__ AS est_usd_list,
       IFF(__CREDIT_PRICE__ IS NULL, 'unpriced', 'priced') AS price_basis,
       CAST(NULL AS VARCHAR) AS not_assessed_reason,
       CASE
         WHEN max_hours >= :crit_hours OR credits >= :crit_credits THEN 'CRITICAL'
         ELSE 'WARN'
       END AS status
FROM g
ORDER BY max_hours DESC
