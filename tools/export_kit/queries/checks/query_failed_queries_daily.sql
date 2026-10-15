-- query_id: query_failed_queries_daily
-- title: Failed and canceled queries by day
-- domain: performance   tier: standard
-- windowed: yes
-- reads: SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :period_days (default 30) days of history the check looks at, counted back from the export
--   date; :warn_failed_count (default 5) failed/canceled query count per day+warehouse+statement_type
--   that flags WARN; :crit_failed_count (default 20) ... that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account.
-- read_this: One row = a day + warehouse + status + statement_type of failed or canceled queries,
--   broken out by who ran them. The columns that matter are query_count (how many failed or were
--   canceled that day) and error_message_sample (a de-identified shape of the most recent error) -
--   a repeated high count on the same warehouse/statement_type points to a systemic issue (bad
--   credentials, a broken task, schema drift), not one-off flakiness.
-- healthy: query_count below :warn_failed_count per day+warehouse+statement_type (field heuristic -
--   tune :warn_failed_count for your account).
-- investigate_if: query_count at/above :warn_failed_count (WARN) or :crit_failed_count (CRITICAL) -
--   field heuristic; a spike concentrated on one warehouse or statement_type is the real signal.
-- actions: 1) read error_message_sample for the shape of the failure and check the calling task,
--   tool or notebook logs for the un-redacted detail (free); 2) fix the query, permission, or
--   schema issue it points to, or add a retry/backoff in the caller (config); 3) if failures
--   cluster around an unstable warehouse (capacity errors), resize it or move the workload to a
--   more resilient one (spend).
-- next: none
-- caveats: Snowflake version: FAIL and INCIDENT map to FAILED, error 604 to CANCELED; compute_type is
--   WAREHOUSE, or CLOUD_SERVICES for a statement that ran without a warehouse.
WITH f AS (
  SELECT DATE(start_time) AS day,
         IFF(warehouse_id IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type,
         TO_VARCHAR(warehouse_id) AS warehouse_id,
         IFF(error_code = 604, 'CANCELED', 'FAILED') AS execution_status,
         query_type AS statement_type, user_name AS executed_by,
         total_elapsed_time, execution_time, error_message, start_time
  FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND execution_status IN ('FAIL', 'INCIDENT')
)
SELECT :period_days AS window_days, day, __ACCOUNT_ID__ AS account_id, compute_type, warehouse_id,
       execution_status, statement_type, executed_by,
       COUNT(*) AS query_count,
       SUM(total_elapsed_time) AS total_duration_ms_sum,
       SUM(execution_time) AS execution_duration_ms_sum,
       -- the latest error, de-valued: emails, then single-quoted literals
       REGEXP_REPLACE(
         REGEXP_REPLACE(MAX_BY(error_message, start_time), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'),
         '''[^'']*''', '?') AS error_message_sample,
       CASE
         WHEN COUNT(*) >= :crit_failed_count THEN 'CRITICAL'
         WHEN COUNT(*) >= :warn_failed_count THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM f
GROUP BY day, compute_type, warehouse_id, execution_status, statement_type, executed_by
ORDER BY query_count DESC
