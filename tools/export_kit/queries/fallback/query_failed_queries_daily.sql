-- query_id: query_failed_queries_daily
-- reads: INFORMATION_SCHEMA.QUERY_HISTORY (table function)
-- fallback_note: last 7 days at most, only the queries this role can see
-- Same columns as checks/query_failed_queries_daily.sql. The table function names failures
-- FAILED_WITH_ERROR / FAILED_WITH_INCIDENT; the warehouse name stands in for its id.
WITH -- The INFORMATION_SCHEMA fallback's query feed, shared by the fallback checks: the slices of
-- common/is_query_history_feed.sql that the export ran before the checks, one row per query id.
is_query_history AS (
  SELECT * FROM (__IS_QUERY_HISTORY_SCANS__)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY end_time DESC) = 1
),
f AS (
  SELECT DATE(start_time) AS day,
         IFF(warehouse_name IS NULL, 'CLOUD_SERVICES', 'WAREHOUSE') AS compute_type,
         warehouse_id,
         IFF(TO_VARCHAR(error_code) = '604', 'CANCELED', 'FAILED') AS execution_status,
         query_type AS statement_type, user_name AS executed_by,
         total_elapsed_time, execution_time, error_message, start_time
  FROM is_query_history
  WHERE start_time >= DATEADD(day, -:period_days, __AS_OF_DATE__) AND start_time < __AS_OF_DATE__
    AND UPPER(execution_status) IN ('FAIL', 'INCIDENT', 'FAILED_WITH_ERROR', 'FAILED_WITH_INCIDENT')
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
